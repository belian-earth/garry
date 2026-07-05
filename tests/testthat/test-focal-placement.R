# Decision D11 lock: focal only in stages fed directly by source/warp.
# Decision D12 lock: algebraic-only distributed spatial reductions.

test_that("focal after a reduce barrier raises the structured error", {
  a <- lazy_source("x.tif")
  r <- reduce_over(a, "mean", c("x", "y"))
  f <- focal(r, fn = function(sh) Reduce(`+`, sh), radius = 1L)
  expect_error(collect(f, plan_only = TRUE),
               class = "garry_focal_placement_error")
})

test_that("focal directly on a source or warp is allowed", {
  a <- lazy_source("x.tif")
  f <- focal(a, fn = function(sh) Reduce(`+`, sh), radius = 1L)
  expect_no_error(collect(f, plan_only = TRUE))

  target <- grid_spec("EPSG:4326", extent = c(0, -100, 100, 0),
                      dims = c(50L, 50L))
  fw <- focal(align(a, target), fn = function(sh) Reduce(`+`, sh),
              radius = 1L)
  expect_no_error(collect(fw, plan_only = TRUE))
})

test_that("median over x,y is rejected; over t is planned", {
  a <- lazy_source("x.tif")
  m <- reduce_over(a, "median", c("x", "y"))
  expect_error(collect(m, plan_only = TRUE),
               class = "garry_reduce_unsupported_error")
})

test_that("single-axis spatial reduction is rejected in v1", {
  a <- lazy_source("x.tif")
  r <- reduce_over(a, "mean", "x")
  expect_error(collect(r, plan_only = TRUE),
               class = "garry_reduce_unsupported_error")
})
