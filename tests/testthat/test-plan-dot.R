# DOT export snapshots: a cheap tripwire on plan structure and labels.

test_that("plan_dot renders the focal/reduce pipeline", {
  a <- lazy_source("x.tif")
  f <- focal(a + 1, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  r <- reduce_over(f, "mean", c("x", "y"))
  p <- collect(r, plan_only = TRUE)
  expect_snapshot(cat(plan_dot(p)))
})

test_that("plan_dot renders the NDVI pipeline", {
  a <- lazy_source("nir.tif")
  b <- lazy_source("red.tif")
  p <- collect((a - b) / (a + b), plan_only = TRUE)
  expect_snapshot(cat(plan_dot(p)))
})
