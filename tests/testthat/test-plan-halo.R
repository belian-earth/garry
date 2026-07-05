# Halo propagation: stacked focals accumulate within a stage; barriers
# reset; sources inherit their consumers' halo (D11: halos are satisfied
# by enlarged read windows).

test_that("stacked focals accumulate halo in one stage", {
  a <- lazy_source("x.tif")
  f1 <- focal(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  f2 <- focal(f1, fn = function(sh) Reduce(`+`, sh) / 25, radius = 2L)
  p <- collect(f2, plan_only = TRUE)

  compute <- Filter(function(s) s@kind == "compute", p@stages)
  expect_length(compute, 1L)
  expect_identical(compute[[1L]]@halo, 3L)
  # Source read window enlarged by the same amount.
  expect_identical(p@stages[[1L]]@halo, 3L)
  expect_identical(p@stages[[1L]]@chunks@halo, 3L)
})

test_that("halo resets across a reduce barrier", {
  a <- lazy_source("x.tif")
  f <- focal(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  r <- reduce_over(f, "mean", c("x", "y"))
  p <- collect(r, plan_only = TRUE)

  parts <- Filter(function(s) s@kind %in% c("reduce_partial", "reduce_combine"),
                  p@stages)
  expect_length(parts, 2L)
  for (s in parts) expect_identical(s@halo, 0L)
})

test_that("map-only stages carry no halo", {
  a <- lazy_source("x.tif")
  p <- collect(a * 2 + 1, plan_only = TRUE)
  for (s in p@stages) expect_identical(s@halo, 0L)
})
