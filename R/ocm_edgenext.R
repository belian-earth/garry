# ---------------------------------------------------------------------------
# OmniCloudMask native forward pass: the edgenext_small encoder (timm
# EdgeNeXt) for the OCM v4 ensemble. Same contracts as ocm_blocks.R:
# g_* vocabulary only, weights as plain R arrays, (C, H, W) chunks.
#
# EdgeNeXt specifics:
# - LayerNorms normalise the CHANNEL axis per pixel (channels-first
#   and channels-last LNs are the same arithmetic on a (C, H, W) cube).
# - ConvNeXt-style blocks: depthwise k x k conv, LN, 1x1 MLP (4x
#   expand, exact GELU), layer-scale gamma, residual.
# - SDTA blocks: channel chunks through cumulative depthwise 3x3
#   convs; a Fourier positional embedding (a per-shape CONSTANT built
#   in plain R at trace time, added on the (C, H, W) cube where
#   elementwise addition commutes with the token reshape); then
#   cross-covariance attention (XCA) over channels; then the MLP.
# - XCA runs per head on (C/h, N) token matrices. The head concat is
#   folded into the output projection (out = sum_h Wp[, h] %*% out_h),
#   which sidesteps any cross-branch channel-order hazard; attention
#   statistics are sums over tokens, so the flatten ordering
#   difference between the traced (row-major) and oracle (col-major)
#   branches cancels.
# - Stage downsample: LN then 2x2 stride-2 conv.
# ---------------------------------------------------------------------------

.ocm_ln_eps <- 1e-6

# value (broadcast a (k,1..) shaped plain constant against x) helpers:
# anvl auto-broadcasts scalars only, so per-channel constants go
# through g_broadcast_arrays with an explicit singleton shape.
.ocm_bc <- function(x, v, shape) {
  va <- array(as.numeric(v), shape)
  b <- g_broadcast_arrays(x, if (.g_traced(x)) g_upload(va, "f32") else va)
  b
}
.ocm_add_ch <- function(x, v) {
  b <- .ocm_bc(x, v, c(length(v), 1L, 1L))
  b[[1L]] + b[[2L]]
}
.ocm_mul_ch <- function(x, v) {
  b <- .ocm_bc(x, v, c(length(v), 1L, 1L))
  b[[1L]] * b[[2L]]
}
.ocm_add_col <- function(m, v) {
  b <- .ocm_bc(m, v, c(length(v), 1L))
  b[[1L]] + b[[2L]]
}

# LayerNorm across channels (axis 1) of a (C, H, W) cube, per pixel.
.ocm_ln_ch <- function(x, ln) {
  sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
  cc <- sh[[1L]]
  m <- g_mean(x, dims = 1L) # (H,W)
  d <- x - g_expand(m, 1L, cc)
  v <- g_mean(d * d, dims = 1L) # population var
  xn <- d / g_expand(sqrt(v + .ocm_ln_eps), 1L, cc)
  .ocm_add_ch(.ocm_mul_ch(xn, ln$g), ln$b)
}

.ocm_gelu <- function(x) 0.5 * x * (1 + g_erf(x / sqrt(2)))

# 1x1 "linear over channels" via conv (weight (out, in) reshaped).
.ocm_fc <- function(x, fc) {
  w <- array(fc$w, c(dim(fc$w)[[1L]], dim(fc$w)[[2L]], 1L, 1L))
  g_conv2d(x, w, fc$b)
}

# ConvNeXt block: depthwise conv, LN, MLP, layer scale, residual.
.ocm_edgenext_convblock <- function(x, blk) {
  k <- dim(blk$conv_dw$w)[[3L]]
  cc <- dim(blk$conv_dw$w)[[1L]]
  h <- g_conv2d(
    x,
    blk$conv_dw$w,
    blk$conv_dw$b,
    padding = k %/% 2L,
    groups = cc
  )
  hn <- .ocm_ln_ch(h, blk$norm)
  hn <- .ocm_gelu(.ocm_fc(hn, blk$fc1))
  hn <- .ocm_fc(hn, blk$fc2)
  hn <- .ocm_mul_ch(hn, blk$gamma)
  x + hn
}

# timm PositionalEncodingFourier as a plain R (dim, H, W) array: row
# and column ramps normalised to 2*pi through a 32-bin sin/cos bank
# (y bank first), then the learned 1x1 projection folded in.
.ocm_pos_embed <- function(h, w, pos) {
  hd <- 32L
  temp <- 1e4
  scale <- 2 * pi
  eps <- 1e-6
  ye <- matrix(seq_len(h), h, w) / (h + eps) * scale
  xe <- matrix(rep(seq_len(w), each = h), h, w) / (w + eps) * scale
  dim_t <- temp^(2 * floor((seq_len(hd) - 1L) / 2) / hd)
  bank <- function(e) {
    out <- array(0, c(hd, h, w))
    for (i in seq_len(hd %/% 2L)) {
      p <- e / dim_t[[2L * i - 1L]] # pair shares a frequency
      out[2L * i - 1L, , ] <- sin(p)
      out[2L * i, , ] <- cos(p)
    }
    out
  }
  feat <- array(0, c(2L * hd, h, w))
  feat[seq_len(hd), , ] <- bank(ye)
  feat[hd + seq_len(hd), , ] <- bank(xe)
  wp <- matrix(pos$w, dim(pos$w)[[1L]], dim(pos$w)[[2L]]) # (dim, 64)
  array(wp %*% matrix(feat, nrow = 2L * hd) + pos$b, c(dim(pos$w)[[1L]], h, w))
}

# Cross-covariance attention on (C, N) tokens, heads statically
# unrolled; returns (C, N).
.ocm_xca_tokens <- function(xt, xca, n) {
  cc <- dim(xca$proj$w)[[1L]]
  heads <- length(xca$temperature)
  chd <- cc %/% heads
  qkv <- .ocm_add_col(matrix(xca$qkv$w, 3L * cc, cc) %*% xt, xca$qkv$b)
  l2n <- function(m) {
    s <- sqrt(g_sum(m * m, dims = 2L)) # row norms over tokens
    m / g_expand(g_ifelse(s > 1e-12, s, 1e-12), 2L, n)
  }
  sm_rows <- function(a, k) {
    # stable softmax over rows
    mx <- g_max(a, dims = 2L)
    e <- exp(a - g_expand(mx, 2L, k))
    e / g_expand(g_sum(e, dims = 2L), 2L, k)
  }
  out <- NULL
  for (hh in seq_len(heads)) {
    rows <- (hh - 1L) * chd
    q <- l2n(g_slice_t(qkv, rows + 1L, rows + chd))
    k <- l2n(g_slice_t(qkv, cc + rows + 1L, cc + rows + chd))
    v <- g_slice_t(qkv, 2L * cc + rows + 1L, 2L * cc + rows + chd)
    attn <- sm_rows((q %*% g_transpose(k)) * xca$temperature[[hh]], chd)
    oh <- attn %*% v # (chd, N)
    wp_h <- xca$proj$w[, rows + seq_len(chd), drop = FALSE]
    contrib <- wp_h %*% oh # head concat folded in
    out <- if (is.null(out)) contrib else out + contrib
  }
  .ocm_add_col(out, xca$proj$b)
}

# SDTA (split-transpose) block.
.ocm_edgenext_sdta <- function(x, blk) {
  sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
  cc <- sh[[1L]]
  h <- sh[[2L]]
  w <- sh[[3L]]
  shortcut <- x

  # channel chunks through cumulative depthwise 3x3 convs; the last
  # chunk passes through raw (torch.chunk sizing: ceil for all but
  # the remainder tail)
  nch <- length(blk$convs) + 1L
  wid <- as.integer(ceiling(cc / nch))
  bounds <- c(seq(0L, by = wid, length.out = nch), cc)
  chunk <- function(i) g_slice_t(x, bounds[[i]] + 1L, min(bounds[[i + 1L]], cc))
  spo <- vector("list", nch)
  sp <- chunk(1L)
  for (i in seq_along(blk$convs)) {
    if (i > 1L) {
      sp <- sp + chunk(i)
    }
    cw <- blk$convs[[i]]
    sp <- g_conv2d(sp, cw$w, cw$b, padding = 1L, groups = dim(cw$w)[[1L]])
    spo[[i]] <- sp
  }
  spo[[nch]] <- chunk(nch)
  x <- g_concat_t(spo)

  # positional embedding (stage 2's SDTA only): per-shape constant
  if (!is.null(blk$pos)) {
    x <- x +
      (if (.g_traced(x)) {
        g_upload(.ocm_pos_embed(h, w, blk$pos), "f32")
      } else {
        .ocm_pos_embed(h, w, blk$pos)
      })
  }

  # XCA on tokens, gamma_xca residual
  xt <- .g_flatten_yx(x)
  xn <- .ocm_ln_tokens(xt, blk$norm_xca, cc, h * w)
  xt <- xt +
    .ocm_mul_col_tokens(.ocm_xca_tokens(xn, blk$xca, h * w), blk$gamma_xca)
  x <- .g_unflatten_kyx(xt, cc, h, w)

  # inverted bottleneck MLP, gamma, residual (on the cube)
  hn <- .ocm_ln_ch(x, blk$norm)
  hn <- .ocm_gelu(.ocm_fc(hn, blk$fc1))
  hn <- .ocm_fc(hn, blk$fc2)
  hn <- .ocm_mul_ch(hn, blk$gamma)
  shortcut + hn
}

# LayerNorm / per-channel scale on (C, N) token matrices.
.ocm_ln_tokens <- function(xt, ln, cc, n) {
  m <- g_mean(xt, dims = 1L) # (N,) per token
  d <- xt - g_expand(m, 1L, cc)
  v <- g_mean(d * d, dims = 1L)
  xn <- d / g_expand(sqrt(v + .ocm_ln_eps), 1L, cc)
  b <- .ocm_bc(xn, ln$g, c(cc, 1L))
  out <- b[[1L]] * b[[2L]]
  b2 <- .ocm_bc(out, ln$b, c(cc, 1L))
  b2[[1L]] + b2[[2L]]
}
.ocm_mul_col_tokens <- function(m, v) {
  b <- .ocm_bc(m, v, c(length(v), 1L))
  b[[1L]] * b[[2L]]
}

# edgenext_small encoder: stem (4x4 s4 conv + LN) then 4 stages
# (downsample LN + 2x2 s2 conv for stages 2..4). Returns the 4-level
# feature pyramid (1/4, 1/8, 1/16, 1/32).
.ocm_edgenext_encoder <- function(x, W) {
  h <- g_conv2d(x, W$stem$conv$w, W$stem$conv$b, stride = 4L)
  h <- .ocm_ln_ch(h, W$stem$ln)
  feats <- vector("list", 4L)
  for (s in 1:4) {
    st <- W$stages[[s]]
    if (!is.null(st$downsample)) {
      h <- .ocm_ln_ch(h, st$downsample$ln)
      h <- g_conv2d(h, st$downsample$conv$w, st$downsample$conv$b, stride = 2L)
    }
    for (blk in st$blocks) {
      h <- if (isTRUE(blk$sdta)) {
        .ocm_edgenext_sdta(h, blk)
      } else {
        .ocm_edgenext_convblock(h, blk)
      }
    }
    feats[[s]] <- h
  }
  feats
}

# Full single-model forward on a normalised, /32-divisible (3,H,W)
# window -> (4,H,W) logits. Skips: 1/16, 1/8, 1/4, then two skipless
# upsamples to full resolution (edgenext has no 1/2 level).
.ocm_forward_edgenext <- function(x, W) {
  f <- .ocm_edgenext_encoder(x, W)
  h <- f[[4L]]
  skips <- list(f[[3L]], f[[2L]], f[[1L]], NULL, NULL)
  for (i in 1:5) {
    h <- .ocm_decoder_block(h, skips[[i]], W$decoder[[i]])
  }
  g_conv2d(h, W$head$w, W$head$b, padding = 1L)
}
