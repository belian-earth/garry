# Decision D15 lock: the differentiability boundary is structural.

skip_if_not_installed("anvl")

.simple_kernel_loss <- function() {
  a <- lazy_source(fixture_gradient_f32())
  fk <- focal_kernel(a / 1000, matrix(1 / 9, 3, 3))
  list(loss = reduce_over(fk, "mean", c("x", "y")), fk = fk)
}

test_that("warp on the tape is rejected", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(61L, 43L))

  a <- lazy_source(f)
  fk <- focal_kernel(align(a, target), matrix(1 / 9, 3, 3))
  loss <- reduce_over(fk, "mean", c("x", "y"))
  expect_error(lazy_value_and_grad(loss, fk),
               class = "garry_grad_unsupported_error")
})

test_that("arbitrary-fn focal on the tape is rejected", {
  a <- lazy_source(fixture_gradient_f32())
  fo <- focal(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  loss <- reduce_over(fo, "mean", c("x", "y"))
  expect_error(lazy_value_and_grad(loss, fo),
               class = "garry_grad_unsupported_error")
})

test_that("non sum/mean losses are rejected", {
  lp <- .simple_kernel_loss()
  a <- lazy_source(fixture_gradient_f32())
  fk <- focal_kernel(a / 1000, matrix(1 / 9, 3, 3))
  loss_max <- reduce_over(fk, "max", c("x", "y"))
  expect_error(lazy_value_and_grad(loss_max, fk),
               class = "garry_grad_unsupported_error")
})

test_that("wrt outside the loss pipeline is rejected", {
  lp <- .simple_kernel_loss()
  other <- focal_kernel(lazy_source(fixture_i16_nodata()),
                        matrix(1 / 9, 3, 3))
  expect_error(lazy_value_and_grad(lp$loss, other),
               class = "garry_grad_unsupported_error")
})
