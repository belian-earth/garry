# Chunked gradients equal unchunked gradients (linearity of sum/mean).

skip_if_not_installed("anvl")

test_that("kernel gradient is identical across chunk sizes", {
  f <- fixture_gradient_f32()
  k0 <- matrix(c(0.1, 0.3, 0,
                 0.2, 0.1, 0.1,
                 0, 0.15, 0.05), 3, 3, byrow = TRUE)
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000, k0)
  loss <- reduce_over(fk, "mean", c("x", "y"))

  run <- function(px) {
    old <- options(garry.chunk_target_px = px)
    on.exit(options(old))
    lazy_value_and_grad(loss, fk)
  }

  whole <- run(1e6)
  for (px in c(17 * 13, 29 * 23)) {
    got <- run(px)
    expect_equal(got$grad, whole$grad, tolerance = 1e-6,
                 label = paste("px", px))
    expect_equal(got$value, whole$value, tolerance = 1e-6)
  }
})

test_that("sum-loss gradients are chunk-invariant on nodata rasters", {
  f <- fixture_i16_nodata()
  k0 <- matrix(0.1, 3, 3)
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000, k0)
  loss <- reduce_over(fk, "sum", c("x", "y"))

  run <- function(px) {
    old <- options(garry.chunk_target_px = px)
    on.exit(options(old))
    lazy_value_and_grad(loss, fk)
  }
  whole <- run(1e6)
  got <- run(19 * 17)
  expect_equal(got$grad, whole$grad, tolerance = 1e-5)
  expect_equal(got$value, whole$value, tolerance = 1e-5)
})
