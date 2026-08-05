# ---------------------------------------------------------------------------
# OmniCloudMask native forward pass: shared blocks + the regnety_004
# SMP U-Net (design/plan: native OCM, P2). Everything is written in the
# g_* vocabulary so one body runs traced (anvl -> XLA kernel) and
# untraced (the pure-R oracle); weights are plain R arrays from
# ocm_load_weights(), entering traced kernels as compile-time
# constants.
#
# Input contract: a (3, H, W) chunk of red, green, NIR (any consistent
# scaling; the per-window channel_norm removes offset and scale), NaN
# nodata (D8). H and W must be known at trace time; the U-Net needs
# /32-divisible spatial dims, which the caller guarantees via
# g_pad_rb() (see .ocm_forward()).
# ---------------------------------------------------------------------------

.ocm_relu <- function(x) (x + abs(x)) / 2
.ocm_sigmoid <- function(x) 1 / (1 + exp(-x))

# OCM's channel_norm: per band over the whole window, mean/std of the
# VALID pixels (population std, std 0 -> 1), invalid filled with 0.
# Returns list(x = normalised (3,H,W), invalid = (H,W) 0/1 plane of
# pixels with any invalid band) so the caller can NaN-mask the output.
.ocm_channel_norm <- function(x) {
  sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
  h <- sh[[2L]]; w <- sh[[3L]]
  bad <- g_cast(g_is_nodata(x), "f32")             # (3,H,W)
  ok  <- 1 - bad
  x0  <- g_ifelse(bad > 0, 0, x)
  n   <- g_sum(ok, dims = c(2L, 3L))               # (3,)
  n1  <- g_ifelse(n > 0, n, 1)                     # all-invalid band: avoid 0/0
  m   <- g_sum(x0, dims = c(2L, 3L)) / n1
  mf  <- g_expand(g_expand(m, 2L, h), 3L, w)       # (3,H,W)
  dev <- (x0 - mf) * ok
  v   <- g_sum(dev * dev, dims = c(2L, 3L)) / n1
  sd  <- sqrt(v)
  sd  <- g_ifelse(sd > 0, sd, 1)                   # channel_norm: std 0 -> 1
  sdf <- g_expand(g_expand(sd, 2L, h), 3L, w)
  xn  <- g_ifelse(bad > 0, 0, (x - mf) / sdf)
  invalid <- g_max(bad, dims = 1L)                 # (H,W): any band invalid
  list(x = xn, invalid = invalid)
}

# Squeeze-and-excitation: global average, two 1x1 convs (run on the
# (C,1,1) pooled "image" so the same conv op serves), sigmoid gate.
.ocm_se <- function(x, fc1, fc2) {
  s <- g_mean(x, dims = c(2L, 3L))                 # (C,)
  s <- g_expand(g_expand(s, 2L, 1L), 3L, 1L)       # (C,1,1)
  z <- .ocm_relu(g_conv2d(s, fc1$w, fc1$b))
  z <- .ocm_sigmoid(g_conv2d(z, fc2$w, fc2$b))     # (C,1,1)
  b <- g_broadcast_arrays(x, z)
  b[[1L]] * b[[2L]]
}

# One regnety Y block: 1x1 -> grouped 3x3 (stride on the stage's first
# block) -> SE -> 1x1, residual (1x1 stride-2 projection when present),
# ReLU after the add. BNs are pre-folded into the conv weights/biases.
.ocm_regnety_block <- function(x, blk) {
  s <- if (!is.null(blk$downsample)) 2L else 1L
  h <- .ocm_relu(g_conv2d(x, blk$conv1$w, blk$conv1$b))
  h <- .ocm_relu(g_conv2d(h, blk$conv2$w, blk$conv2$b, stride = s,
                          padding = 1L, groups = blk$groups))
  h <- .ocm_se(h, blk$se_fc1, blk$se_fc2)
  h <- g_conv2d(h, blk$conv3$w, blk$conv3$b)
  idn <- if (!is.null(blk$downsample))
    g_conv2d(x, blk$downsample$w, blk$downsample$b, stride = 2L)
  else x
  .ocm_relu(idn + h)
}

# regnety_004 encoder: stem (3x3 s2) + 4 stages. Returns the feature
# pyramid the SMP decoder consumes: list(stem 1/2, s1 1/4, s2 1/8,
# s3 1/16, s4 1/32).
.ocm_regnety_encoder <- function(x, W) {
  f0 <- .ocm_relu(g_conv2d(x, W$stem$w, W$stem$b, stride = 2L,
                           padding = 1L))
  feats <- vector("list", 5L)
  feats[[1L]] <- f0
  h <- f0
  for (s in 1:4) {
    for (blk in W$stages[[s]]) h <- .ocm_regnety_block(h, blk)
    feats[[s + 1L]] <- h
  }
  feats
}

# One SMP Unet decoder block: nearest x2 upsample, skip concat (when the
# level has one), two 3x3 conv+ReLU (BN folded).
.ocm_decoder_block <- function(x, skip, blk) {
  h <- g_upsample2x(x)
  if (!is.null(skip)) h <- g_concat_t(list(h, skip))
  h <- .ocm_relu(g_conv2d(h, blk$conv1$w, blk$conv1$b, padding = 1L))
  .ocm_relu(g_conv2d(h, blk$conv2$w, blk$conv2$b, padding = 1L))
}

# Full single-model forward on a normalised, /32-divisible (3,H,W)
# window -> (4,H,W) logits.
.ocm_forward_regnety <- function(x, W) {
  f <- .ocm_regnety_encoder(x, W)
  h <- f[[5L]]
  skips <- list(f[[4L]], f[[3L]], f[[2L]], f[[1L]], NULL)
  for (i in 1:5) h <- .ocm_decoder_block(h, skips[[i]], W$decoder[[i]])
  g_conv2d(h, W$head$w, W$head$b, padding = 1L)
}

# First-max-wins argmax over the 4 class planes of (4,H,W) logits ->
# (H,W) classes 0..3 (numpy/torch tie semantics: strictly-greater
# challenger wins).
.ocm_argmax4 <- function(logits) {
  best <- g_squeeze1(g_slice_t(logits, 1L, 1L))
  cls  <- best * 0
  for (k in 1:3) {
    ck <- g_squeeze1(g_slice_t(logits, k + 1L, k + 1L))
    m  <- ck > best
    cls  <- g_ifelse(m, k, cls)
    best <- g_ifelse(m, ck, best)
  }
  cls
}

# edgenext_small forward (P5); defined here so the dispatch below is
# complete.
.ocm_forward_edgenext <- function(x, W) {
  cli::cli_abort("edgenext forward not implemented yet (P5)")
}

# The complete OCM inference body on a raw (3, H, W) window (any H, W):
# channel_norm, pad right/bottom to /32, forward each requested model,
# average logits (OCM ensembles raw logits; argmax(mean) == OCM's
# argmax(blend)), slice back, argmax, NaN where input was invalid.
# `weights` is ocm_load_weights()$weights. Returns (H, W) classes.
.ocm_infer <- function(x, weights) {
  sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
  h <- sh[[2L]]; w <- sh[[3L]]
  dy <- (32L - h %% 32L) %% 32L
  dx <- (32L - w %% 32L) %% 32L
  cn <- .ocm_channel_norm(x)
  xn <- if (dy > 0L || dx > 0L) g_pad_rb(cn$x, dy, dx, value = 0) else cn$x
  logits <- NULL
  for (W in weights) {
    l <- switch(W$arch,
      regnety_004    = .ocm_forward_regnety(xn, W),
      edgenext_small = .ocm_forward_edgenext(xn, W),
      cli::cli_abort("unknown OCM arch {.val {W$arch}}"))
    logits <- if (is.null(logits)) l else logits + l
  }
  logits <- logits / length(weights)
  if (dy > 0L || dx > 0L) {
    # trim the alignment pad off the last two dims
    sh4 <- if (.g_traced(logits)) .g_shape(logits) else dim(logits)
    logits <- g_shift_slice(logits, 0L, 0L, h, w, 0L)
  }
  cls <- .ocm_argmax4(logits)
  g_ifelse(cn$invalid > 0, NaN, cls)
}
