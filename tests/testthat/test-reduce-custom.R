# Custom anvl reducer on ReduceNode (IR extension): reduce_over() accepts an
# anvl kernel fn(x, dims) that collapses the reduce axis. Gates: a custom
# reducer that re-expresses a builtin op matches it; an arbitrary reducer
# (range) equals the manual max - min; a reduce over space has no custom
# partial, so the plan refuses it. test-route-kernels.R holds the range across
# chunked spatial tiles on daemons, each carrying the full t axis.

build_stack <- function(f, red, nan_rm = TRUE) {
  a <- lazy_source(f)
  b <- lazy_source(f)
  reduce_over(lazy_stack(list(a + 1, b * 2)), red, "t", nan_rm = nan_rm)
}

test_that("a custom reducer re-expressing a builtin matches it", {
  f <- fixture_gradient_f32()
  sum_fn <- function(x, dims) g_sum(x, dims = dims, nan_rm = TRUE)
  custom  <- execute_plan(plan_lazy(build_stack(f, sum_fn)))
  builtin <- execute_plan(plan_lazy(build_stack(f, "sum")))
  m <- .fixture_values(60, 40)
  expect_equal(custom, (m + 1) + m * 2, tolerance = 1e-6, ignore_attr = TRUE)
  expect_equal(custom, builtin, tolerance = 1e-6)
})

test_that("a custom reducer runs arbitrary anvl math (range = max - min)", {
  f <- fixture_gradient_f32()
  range_fn <- function(x, dims) {
    g_max(x, dims = dims, nan_rm = TRUE) - g_min(x, dims = dims, nan_rm = TRUE)
  }
  got <- execute_plan(plan_lazy(build_stack(f, range_fn)))
  m <- .fixture_values(60, 40)
  expect_equal(got, abs(m * 2 - (m + 1)), tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a custom reducer cannot be split over spatial dims", {
  f <- fixture_gradient_f32()
  spatial_mean <- function(x, dims) g_mean(x, dims = dims, nan_rm = TRUE)
  # A custom reducer has no algebraic partial/combine, so the planner refuses
  # to reduce it across spatial chunks (unlike sum/mean/min/max/count), on any
  # route. Over t it is fine.
  expect_error(
    plan_lazy(reduce_over(lazy_source(f), spatial_mean, c("x", "y"))),
    class = "garry_reduce_unsupported_error"
  )
})
