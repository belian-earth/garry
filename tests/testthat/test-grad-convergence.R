# Phase 6 exit criterion: recover a 3x3 convolution kernel from
# input/output rasters by gradient descent THROUGH THE FULL PRODUCT PATH
# (lazy sources, planner, chunked executor, mask-form gradients).

skip_if_not_installed("anvl")

test_that("kernel recovery converges through the product path", {
  fx <- fixture_random_f32()   # noise: identifiable (linear surfaces are
                               # invariant to symmetric mass-1 kernels)
  k_true <- matrix(c(0.05, 0.1, 0.05,
                     0.10, 0.4, 0.10,
                     0.05, 0.1, 0.05), 3, 3, byrow = TRUE)

  # Synthetic target: y = conv(x, k_true), materialised to disk so it
  # enters the loss as a real source.
  a0 <- lazy_source(fx)
  y_path <- tempfile(fileext = ".tif")
  collect(focal_kernel(a0, k_true), path = y_path)

  build_loss <- function() {
    a <- lazy_source(fx)
    y <- lazy_source(y_path, graph = a@graph)
    fk <- focal_kernel(a, matrix(1 / 9, 3, 3))
    d <- fk - y
    list(loss = reduce_over(d * d, "mean", c("x", "y")), fk = fk)
  }
  lp <- build_loss()

  k_est <- matrix(1 / 9, 3, 3)
  lr <- 0.2
  losses <- numeric(0)
  for (step in 1:300) {
    r <- lazy_value_and_grad(lp$loss, lp$fk, weights = k_est)
    k_est <- k_est - lr * r$grad
    losses <- c(losses, r$value)
  }
  err <- max(abs(k_est - k_true))
  expect_lt(err, 1e-3)
  expect_lt(losses[[length(losses)]], 1e-7)
  expect_lt(losses[[length(losses)]], losses[[1]])
})
