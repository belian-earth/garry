# What a kernel's own test file and test-route-kernels.R share: small noise
# stacks, whose pixels differ, so a per-pixel reference checks many decisions
# rather than one scaled pattern, and references in pure R.

# Some cells missing and some not. A hole threshold outside a fixture's value
# range leaves a stack with no gaps, or with nothing but gaps, and the test
# over it passes all the same.
.expect_partial_nan <- function(x, info = NULL) {
  expect_true(any(is.nan(x)), info = info)
  expect_false(all(is.nan(x)), info = info)
}

# One Float32 source per leading slice of a (slice, y, x) array.
.slice_sources <- function(cube, graph = graph_new()) {
  d <- dim(cube)
  lapply(seq_len(d[[1L]]), function(i) {
    lazy_source(fixture_tile(t(cube[i, , ]), nx = d[[3L]], ny = d[[2L]]), graph = graph)
  })
}

# 6 slices of 8 x 12 f32 noise as (t, y, x). Holes fall in some columns and
# spikes, 40 times the rest, in the others, where a full window repairs them.
.hampel_cube <- function() {
  spiked <- c(2L, 5L, 8L, 11L)
  cube <- withr::with_seed(61L, {
    v <- array(stats::rnorm(576L, 100, 4), c(6L, 8L, 12L))
    v[, , -spiked][sample(384L, 60L)] <- NaN
    v[3L, 2:7, spiked] <- v[3L, 2:7, spiked] * 40
    v
  })
  .as_f32(cube)
}

.hampel_stack <- function() lazy_stack(.slice_sources(.hampel_cube()), along = "t")

# A centred window clipped at the series ends, per pixel of a (t, y, x) array.
.ref_hampel <- function(cube, k, t0) {
  one <- function(v) {
    n <- length(v)
    out <- v
    for (t in seq_len(n)) {
      w <- v[max(1L, t - k):min(n, t + k)]
      med <- stats::median(w, na.rm = TRUE)
      mad <- 1.4826 * stats::median(abs(w - med), na.rm = TRUE)
      if (is.finite(v[t]) && abs(v[t] - med) > t0 * mad) out[t] <- med
    }
    out
  }
  apply(cube, c(2L, 3L), one)
}

# 2 bands x 4 dates of 8 x 12 f32 noise as (band, t, y, x): date 3 is masked
# in a region, both bands as a shared cloud mask would be, one pixel on every
# date, and one pixel in one band of one date, which loses that date.
.mb_values <- function() {
  v <- withr::with_seed(62L, array(stats::rnorm(768L, 50, 10), c(2L, 4L, 8L, 12L)))
  v[, 3L, 3:5, 4:9] <- NaN
  v[, , 8L, 12L] <- NaN
  v[1L, 2L, 1L, 1L] <- NaN
  .as_f32(v)
}

.mb_cube <- function() {
  v <- .mb_values()
  g <- graph_new()
  band <- function(b) {
    lazy_stack(stats::setNames(.slice_sources(v[b, , , ], g), paste0("t", 1:4)), along = "t")
  }
  lazy_stack(list(A = band(1L), B = band(2L)), along = "band")
}

# Weiszfeld at one pixel, Y (band, t) with NaN columns on masked dates.
.ref_wz <- function(Y, iters = 12L, eps = 1e-7) {
  ok <- colSums(is.na(Y)) == 0L
  if (!any(ok)) return(rep(NaN, nrow(Y)))
  Yv <- Y[, ok, drop = FALSE]
  m <- rowMeans(Yv)
  for (k in seq_len(iters)) {
    d <- sqrt(colSums((Yv - m)^2))
    w <- 1 / (d + eps)
    m <- as.vector(Yv %*% w) / sum(w)
  }
  m
}

# A reference over every pixel of a (band, t, y, x) array, (band, y, x) back.
.ref_pixels <- function(v, f) apply(v, c(3L, 4L), f)

# An array with a leading axis as collect() returns it, that axis last.
.outer_last <- function(x) aperm(x, c(2L, 3L, 1L))

# Translation-invariant toy body: collapse band, add two fixed shifts.
# Size-preserving; needs radius >= 2 to crop the pad-contaminated ring,
# so chunked results must equal whole-frame results exactly.
.toy_patch_fn <- function(x) {
  s <- g_sum(x, dims = 1L)
  sh <- if (garry:::.g_traced(s)) garry:::.g_shape(s) else dim(s)
  sp <- g_pad(s, 2L, value = 0)
  s + 0.5 * g_shift_slice(sp, 2L, 0L, sh[[1L]], sh[[2L]], 2L) +
    0.25 * g_shift_slice(sp, 0L, -2L, sh[[1L]], sh[[2L]], 2L)
}

.toy_patch <- function(out_bands = 0L, kernel_id = "toy-v1") {
  f <- fixture_gradient_f32()
  g <- graph_new()
  st <- lazy_stack(list(lazy_source(f, graph = g),
                        lazy_source(f, graph = g) * 2), along = "band")
  lazy_patch(st, .toy_patch_fn, radius = 2L, out_bands = out_bands,
             kernel_id = kernel_id, bytes_px = 64, flops_px = 500)
}

# .toy_patch() in plain R: the sum of the bands, half the cell two rows down
# and a quarter of the cell two columns left, NaN where either leaves the raster.
.toy_patch_want <- function() {
  s <- .fixture_values(60, 40) * 3
  down <- left <- s * NaN
  down[1:38, ] <- s[3:40, ]
  left[, 3:60] <- s[, 1:58]
  s + 0.5 * down + 0.25 * left
}

# Two slices of the gradient fixture, both NaN at the cells <= 2000.
.allnan_stack <- function() {
  x <- lazy_source(fixture_gradient_f32())
  a <- lazy_map(x, fn = function(v) g_ifelse(v > 2000, v, NaN))
  b <- lazy_map(x, fn = function(v) g_ifelse(v > 2000, v * 2, NaN))
  lazy_stack(list(a = a, b = b))
}

# A noise plane with holes, whose windows weigh their cells differently.
.bilateral_plane <- function() .hampel_cube()[1L, , ]

.bilateral_source <- function() {
  m <- .bilateral_plane()
  .slice_sources(array(m, c(1L, dim(m))))[[1L]]
}

# The bilateral filter's cell loop, the one rf_bilateral runs.
.ref_bilateral <- function(m, sigma_d, sigma_r) {
  ny <- nrow(m); nx <- ncol(m)
  out <- matrix(NaN, ny, nx)
  for (i in seq_len(ny)) for (j in seq_len(nx)) {
    x0 <- m[i, j]
    if (is.na(x0)) next
    num <- 0; den <- 0
    for (di in -1:1) for (dj in -1:1) {
      ii <- i + di; jj <- j + dj
      if (ii < 1 || ii > ny || jj < 1 || jj > nx) next
      v <- m[ii, jj]
      if (is.na(v)) next
      w <- exp(-(di^2 + dj^2) / (2 * sigma_d^2)) *
        exp(-(v - x0)^2 / (2 * sigma_r^2))
      num <- num + w * v; den <- den + w
    }
    out[i, j] <- num / den
  }
  out
}
