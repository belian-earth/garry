# bilateral_focal(): the edge-preserving 3x3 filter as a fused focal body.
# Gates: exact parity with rustyfilters::rf_bilateral (edge = "shrink",
# na_policy = "omit") on dense, NaN-holed, and edge pixels -- untraced and
# through a full traced plan.

# pure-R reference mirroring rf_bilateral's cell loop
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

test_that("bilateral_focal matches the reference and rf_bilateral (untraced)", {
  set.seed(31)
  m <- matrix(rnorm(40 * 30), 40, 30)
  m[10, 10] <- 8                      # sharp spike (edge preservation)
  m[c(5, 20), c(7, 15)] <- NaN        # holes
  sr <- 1.3; sd_ <- 1

  fn <- bilateral_focal(sigma_r = sr, sigma_d = sd_)
  # drive the body exactly as .eval_node does: NaN-padded shifts
  pad <- g_pad(m, 1L, NaN)
  shifts <- lapply(seq_len(9), function(k) {
    off <- expand.grid(dx = -1:1, dy = -1:1)
    g_shift_slice(pad, off$dy[k], off$dx[k], nrow(m), ncol(m), 1L)
  })
  got <- fn(shifts)
  want <- .ref_bilateral(m, sd_, sr)
  expect_equal(got, want, tolerance = 1e-12)
  expect_identical(is.na(got), is.na(want))

  skip_if_not_installed("rustyfilters")
  rf <- rustyfilters::rf_bilateral(m, sigma_d = sd_, sigma_r = sr,
                                   window = 3L)
  expect_equal(as.numeric(got), as.numeric(rf), tolerance = 1e-10)
})

test_that("bilateral_focal through a traced plan matches rf_bilateral", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("rustyfilters")
  f <- fixture_gradient_f32()
  lr <- lazy_source(f)
  sr <- 2.5
  out <- execute_plan(plan_lazy(
    focal(lr, fn = bilateral_focal(sigma_r = sr), radius = 1L)))

  m <- execute_plan(plan_lazy(lr))
  rf <- rustyfilters::rf_bilateral(m, sigma_d = 1, sigma_r = sr, window = 3L)
  expect_equal(as.numeric(out), as.numeric(rf), tolerance = 1e-4)  # f32 kernel
})

test_that("bilateral_focal validates", {
  expect_error(bilateral_focal(0), "finite positive")
  expect_error(bilateral_focal(1, sigma_d = -1), "finite positive")
  fn <- bilateral_focal(1, radius = 2L)
  expect_error(fn(vector("list", 9L)), "same radius")
})
