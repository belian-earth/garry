# Phase 6 exit criterion: recover a 3x3 convolution kernel from
# input/output rasters by gradient descent THROUGH THE FULL PRODUCT PATH
# (lazy sources, planner, chunked executor, mask-form gradients).


test_that("kernel recovery converges through the product path", {
  fx <- fixture_random_f32()   # noise: identifiable (linear surfaces are
                               # invariant to symmetric mass-1 kernels)
  # Asymmetric: the only route for `weights =`, so a transposition shows.
  k_true <- matrix(c(0.05, 0.2, 0.0,
                     0.10, 0.4, 0.05,
                     0.00, 0.1, 0.10), 3, 3, byrow = TRUE)

  # Centred, so the loss is near-isotropic in the weights and a few steps
  # at one rate recover all of them.
  centred <- function(a) a - 0.5

  # Synthetic target: y = conv(x, k_true), materialised to disk so it
  # enters the loss as a real source.
  a0 <- lazy_source(fx)
  y_path <- tempfile(fileext = ".tif")
  write_tif(focal_kernel(centred(a0), k_true), y_path)

  build_loss <- function() {
    a <- lazy_source(fx)
    y <- lazy_source(y_path, graph = a@graph)
    fk <- focal_kernel(centred(a), matrix(1 / 9, 3, 3))
    d <- fk - y
    list(loss = reduce_over(d * d, "mean", c("x", "y")), fk = fk)
  }
  lp <- build_loss()

  k_est <- matrix(1 / 9, 3, 3)
  lr <- 5
  losses <- numeric(0)
  for (step in 1:20) {
    r <- lazy_value_and_grad(lp$loss, lp$fk, weights = k_est)
    k_est <- k_est - lr * r$grad
    losses <- c(losses, r$value)
    # stop once both exit assertions below already hold; 20 is the
    # divergence backstop, not a required iteration count
    if (r$value < 1e-7 && max(abs(k_est - k_true)) < 1e-3) break
  }
  err <- max(abs(k_est - k_true))
  expect_lt(err, 1e-3)
  expect_lt(losses[[length(losses)]], 1e-7)
  expect_lt(losses[[length(losses)]], losses[[1]])
})

test_that("a loop over new weights reuses its kernels, and the weights reach them", {
  skip_on_os("mac") # .host_kernel() keeps nothing across calls there
  k1 <- matrix(c(0.05, 0.2, 0, 0.1, 0.4, 0.05, 0, 0.1, 0.1), 3, 3, byrow = TRUE)
  k2 <- matrix(c(0.3, 0, 0.1, 0, 0.2, 0, 0.1, 0, 0.3), 3, 3, byrow = TRUE)
  a <- lazy_source(fixture_gradient_f32())
  fk1 <- focal_kernel(a, k1)
  fk2 <- focal_kernel(fk1, k2)
  loss <- reduce_over(fk2, "mean", c("x", "y"))

  # the same loss in plain R, over the cells both windows fill
  focal <- function(m, k) {
    ny <- nrow(m) - 2L
    nx <- ncol(m) - 2L
    out <- matrix(0, ny, nx)
    for (i in 1:3) {
      for (j in 1:3) {
        out <- out + k[i, j] * m[i:(i + ny - 1L), j:(j + nx - 1L)]
      }
    }
    out
  }
  want <- function(w1, w2) mean(focal(focal(.fixture_values(60, 40), w1), w2))

  first <- lazy_value_and_grad(loss, fk1)
  expect_equal(first$value, want(k1, k2), tolerance = 1e-5)
  made <- garry:::.kernel_stats$creates
  second <- lazy_value_and_grad(loss, fk1, weights = 2 * k1)
  expect_identical(garry:::.kernel_stats$creates, made)
  expect_equal(second$value, want(2 * k1, k2), tolerance = 1e-5)
  # the same stage differentiated at another focal is another program
  later <- lazy_value_and_grad(loss, fk2)
  expect_gt(garry:::.kernel_stats$creates, made)
  expect_equal(later$value, want(k1, k2), tolerance = 1e-5)
})
