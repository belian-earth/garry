# Spike 02: focal/stencil ops without a reduce_window primitive.
# Strategy: pad once, take (2h+1)^2 shifted static slices, combine.
# XLA is expected to fuse the slice+add chain into one kernel.

library(anvl)

# -- First: pin down nv_static_slice index conventions on a tiny case. ----
x <- nv_array(matrix(1:12, 3, 4) * 1.0, "f32")
s <- as_array(nv_static_slice(x, start_indices = c(2L, 2L),
                              limit_indices = c(3L, 3L),
                              strides = c(1L, 1L)))
cat("slice convention check (expect rows 2:3, cols 2:3 of 3x4 matrix):\n")
print(s)
ref <- matrix(1:12, 3, 4)[2:3, 2:3]
stopifnot(identical(dim(s), dim(ref)), max(abs(s - ref)) == 0)
cat("=> start/limit are 1-based inclusive\n\n")

# -- Generic focal via shift-and-combine. ---------------------------------
# fn_combine receives a list of (2h+1)^2 shifted arrays (row-major over
# (dy, dx) offsets) and returns one array. Weights etc. close over it.
focal_shifted <- function(xpad, n, m, h, fn_combine) {
  shifts <- list()
  k <- 1L
  for (dy in -h:h) {
    for (dx in -h:h) {
      shifts[[k]] <- nv_static_slice(
        xpad,
        start_indices = c(1L + h + dy, 1L + h + dx),
        limit_indices = c(n + h + dy, m + h + dx),
        strides = c(1L, 1L)
      )
      k <- k + 1L
    }
  }
  fn_combine(shifts)
}

focal_mean_3x3 <- function(x, n, m) {
  xpad <- nv_pad(x, nv_scalar(0, "f32"),
                 edge_padding_low = c(1L, 1L), edge_padding_high = c(1L, 1L))
  s <- focal_shifted(xpad, n, m, 1L, function(sh) Reduce(`+`, sh))
  s / 9
}

npx <- 256L
set.seed(2)
xm <- matrix(runif(npx^2), npx, npx)

f <- jit(focal_mean_3x3, static = c("n", "m"))
got <- as_array(f(nv_array(xm, "f32"), n = npx, m = npx))

# R reference: zero-padded 3x3 mean.
xp <- matrix(0, npx + 2, npx + 2)
xp[2:(npx + 1), 2:(npx + 1)] <- xm
want <- matrix(0, npx, npx)
for (dy in 0:2) for (dx in 0:2)
  want <- want + xp[(1 + dy):(npx + dy), (1 + dx):(npx + dx)]
want <- want / 9

cat("focal mean 3x3 max abs diff:", max(abs(got - want)), "\n")
stopifnot(max(abs(got - want)) < 1e-6)

# -- Weighted kernel (Sobel x) through the same machinery. ----------------
sobel <- matrix(c(-1, 0, 1, -2, 0, 2, -1, 0, 1), 3, 3, byrow = TRUE)
focal_sobel <- function(x, n, m) {
  xpad <- nv_pad(x, nv_scalar(0, "f32"),
                 edge_padding_low = c(1L, 1L), edge_padding_high = c(1L, 1L))
  w <- as.numeric(t(sobel))  # row-major over (dy, dx), matching focal_shifted
  focal_shifted(xpad, n, m, 1L, function(sh) {
    Reduce(`+`, Map(function(a, wi) a * wi, sh, w))
  })
}
fs <- jit(focal_sobel, static = c("n", "m"))
got_s <- as_array(fs(nv_array(xm, "f32"), n = npx, m = npx))

want_s <- matrix(0, npx, npx)
for (i in 1:3) for (j in 1:3)
  want_s <- want_s + sobel[i, j] * xp[(i):(npx + i - 1), (j):(npx + j - 1)]
cat("sobel max abs diff:", max(abs(got_s - want_s)), "\n")
stopifnot(max(abs(got_s - want_s)) < 1e-4)

# -- 5x5 (h = 2) to confirm the pattern scales beyond radius 1. -----------
focal_mean_5x5 <- function(x, n, m) {
  xpad <- nv_pad(x, nv_scalar(0, "f32"),
                 edge_padding_low = c(2L, 2L), edge_padding_high = c(2L, 2L))
  focal_shifted(xpad, n, m, 2L, function(sh) Reduce(`+`, sh)) / 25
}
f5 <- jit(focal_mean_5x5, static = c("n", "m"))
invisible(as_array(f5(nv_array(xm, "f32"), n = npx, m = npx)))

# -- Timing at raster-chunk scale. ----------------------------------------
big <- 2048L
xb <- matrix(runif(big^2), big, big)
ab <- nv_array(xb, "f32")
invisible(as_array(f(ab, n = big, m = big)))  # compile for this shape
t_jit <- system.time(for (i in 1:10) invisible(as_array(f(ab, n = big, m = big))))["elapsed"] / 10

t_r <- system.time({
  xpb <- matrix(0, big + 2, big + 2); xpb[2:(big + 1), 2:(big + 1)] <- xb
  wb <- matrix(0, big, big)
  for (dy in 0:2) for (dx in 0:2)
    wb <- wb + xpb[(1 + dy):(big + dy), (1 + dx):(big + dx)]
  wb <- wb / 9
})["elapsed"]

cat(sprintf("2048x2048 focal mean: jit %.1f ms/call (incl. transfer), R %.1f ms\n",
            t_jit * 1000, t_r * 1000))
cat("PASS: stencils expressible via pad + shifted static slices\n")
