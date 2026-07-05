# Gate 6.0 lock (decision D15): why grad-mode uses the mask-multiply
# rewrite. Gradients THROUGH nan_rm reductions are exact at valid cells
# when differentiating wrt the reduced array itself, but parameter
# gradients are NaN-poisoned whenever nodata multiplies the parameter
# (0 x NaN in the cotangent). The mask form is poison-free and equal.

skip_if_not_installed("anvl")

.nan_data <- function(seed = 60, n = 8) {
  set.seed(seed)
  x <- matrix(runif(n * n), n, n)
  x[sample(n * n, 15)] <- NaN
  x
}

test_that("grads wrt the reduced array: valid cells exact, nodata cells NaN", {
  x <- .nan_data()
  w <- matrix(runif(64), 8, 8)

  vg <- g_value_and_gradient(
    function(w, x) g_mean(w * x, nan_rm = TRUE), wrt = "w")
  r <- vg(g_upload(w, "f32"), g_upload(x, "f32"))
  gw <- g_download(r$grad$w)

  expect_identical(is.nan(gw), is.nan(x))       # poison stays local...
  # ...and valid-cell values are exactly x / n_valid.
  ok <- !is.nan(x)
  expect_equal(gw[ok], x[ok] / sum(ok), tolerance = 1e-5)
})

test_that("parameter grads through nan_rm are fully poisoned (the WHY)", {
  x <- .nan_data(61, 12)
  vg <- g_value_and_gradient(
    function(w, x) {
      # scalar parameter multiplying NaN-bearing data
      g_mean(x * g_index_scalar(w, 1L), nan_rm = TRUE)
    }, wrt = "w")
  r <- vg(g_upload(0.5, "f32"), g_upload(x, "f32"))
  expect_true(all(is.nan(g_download(r$grad$w))))
})

test_that("mask-multiply form is poison-free and matches finite differences", {
  x <- .nan_data(62, 12)
  loss_mask <- function(w, x) {
    m <- g_cast(!g_is_nodata(x), "f32")
    xz <- g_ifelse(g_is_nodata(x), 0, x)
    g_sum(xz * g_index_scalar(w, 1L) * m) / g_sum(m)
  }
  vg <- g_value_and_gradient(loss_mask, wrt = "w")
  r <- vg(g_upload(0.5, "f32"), g_upload(x, "f32"))
  g <- g_download(r$grad$w)
  expect_false(anyNA(g))

  jl <- g_jit(loss_mask)
  eps <- 1e-3
  fd <- (g_download(jl(g_upload(0.5 + eps, "f32"), g_upload(x, "f32"))) -
         g_download(jl(g_upload(0.5 - eps, "f32"), g_upload(x, "f32")))) /
        (2 * eps)
  expect_equal(as.numeric(g), fd, tolerance = 1e-3)
  # And it equals the analytic gradient: mean of valid x.
  expect_equal(as.numeric(g), mean(x[!is.nan(x)]), tolerance = 1e-4)
})
