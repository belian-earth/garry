# Pipeline gradients vs finite differences of collect()'d losses.

skip_if_not_installed("anvl")

.fd_kernel_grad <- function(build_loss, k0, eps = 1e-2) {
  g <- matrix(0, nrow(k0), ncol(k0))
  for (i in seq_len(nrow(k0))) {
    for (j in seq_len(ncol(k0))) {
      kp <- k0; kp[i, j] <- kp[i, j] + eps
      km <- k0; km[i, j] <- km[i, j] - eps
      g[i, j] <- (collect(build_loss(kp)) - collect(build_loss(km))) /
        (2 * eps)
    }
  }
  g
}

test_that("kernel gradient of mean(focal_kernel(x, k)) matches FD", {
  f <- fixture_gradient_f32()
  # Asymmetric kernel: catches any (dy, dx) layout/transpose slip.
  k0 <- matrix(c(0.05, 0.2, 0.0,
                 0.10, 0.4, 0.05,
                 0.00, 0.1, 0.10), 3, 3, byrow = TRUE)

  build <- function(k) {
    a <- lazy_source(f)
    reduce_over(focal_kernel(a / 1000, k), "mean", c("x", "y"))
  }
  loss <- build(k0)
  wrt <- NULL
  # Rebuild to grab the focal handle from the same graph.
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000, k0)
  loss <- reduce_over(fk, "mean", c("x", "y"))

  got <- lazy_value_and_grad(loss, fk)
  fd <- .fd_kernel_grad(build, k0)

  expect_equal(got$grad, fd, tolerance = 5e-3)
  expect_equal(got$value, collect(build(k0)), tolerance = 1e-5)
})

test_that("gradient with maps before and after the focal matches FD", {
  f <- fixture_gradient_f32()
  k0 <- matrix(c(0, 0.3, 0,
                 0.2, 0.1, 0.1,
                 0, 0.3, 0), 3, 3, byrow = TRUE)

  build <- function(k) {
    a <- lazy_source(f)
    fk <- focal_kernel(a / 1000 + 1, k)
    reduce_over(fk * 2 - 1, "sum", c("x", "y"))
  }
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000 + 1, k0)
  loss <- reduce_over(fk * 2 - 1, "sum", c("x", "y"))

  got <- lazy_value_and_grad(loss, fk)
  fd <- .fd_kernel_grad(build, k0, eps = 1e-3)

  expect_equal(got$grad / abs(fd + (fd == 0)),
               fd / abs(fd + (fd == 0)), tolerance = 5e-3)
  expect_equal(got$value, collect(build(k0)), tolerance = 1e-2)
})

test_that("gradients on nodata rasters are poison-free and match FD", {
  f <- fixture_i16_nodata()
  k0 <- matrix(c(0.1, 0.2, 0.05,
                 0.15, 0.3, 0.05,
                 0.05, 0.05, 0.05), 3, 3, byrow = TRUE)
  build <- function(k) {
    a <- lazy_source(f)
    reduce_over(focal_kernel(a / 1000, k), "mean", c("x", "y"))
  }
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000, k0)
  loss <- reduce_over(fk, "mean", c("x", "y"))

  got <- lazy_value_and_grad(loss, fk)
  expect_false(anyNA(got$grad))
  fd <- .fd_kernel_grad(build, k0)
  expect_equal(got$grad, fd, tolerance = 5e-3)
})
