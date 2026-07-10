# Custom anvl reducer on ReduceNode (IR extension): reduce_over() accepts an
# anvl kernel fn(x, dims) that collapses the reduce axis, run identically by the
# single-threaded oracle and the distributed scheduler. Gates: a custom reducer
# that re-expresses a builtin op matches it; an arbitrary reducer (range) equals
# the manual max - min; and the distributed result matches the oracle (so it
# holds across chunked spatial tiles, each carrying the full t axis).

build_stack <- function(f, red, nan_rm = TRUE) {
  a <- lazy_source(f)
  b <- lazy_source(f)
  reduce_over(lazy_stack(list(a + 1, b * 2)), red, "t", nan_rm = nan_rm)
}

test_that("a custom reducer re-expressing a builtin matches it", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  sum_fn <- function(x, dims) g_sum(x, dims = dims, nan_rm = TRUE)
  custom  <- execute_plan(plan_lazy(build_stack(f, sum_fn)))
  builtin <- execute_plan(plan_lazy(build_stack(f, "sum")))
  expect_equal(custom, builtin, tolerance = 1e-6)
})

test_that("a custom reducer runs arbitrary anvl math (range = max - min)", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  range_fn <- function(x, dims) {
    g_max(x, dims = dims, nan_rm = TRUE) - g_min(x, dims = dims, nan_rm = TRUE)
  }
  got <- execute_plan(plan_lazy(build_stack(f, range_fn)))
  mx  <- execute_plan(plan_lazy(build_stack(f, "max")))
  mn  <- execute_plan(plan_lazy(build_stack(f, "min")))
  expect_equal(got, mx - mn, tolerance = 1e-6)
})

test_that("custom reducer: distributed == single-threaded oracle", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)   # force many spatial chunks
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  range_fn <- function(x, dims) {
    g_max(x, dims = dims, nan_rm = TRUE) - g_min(x, dims = dims, nan_rm = TRUE)
  }
  p <- plan_lazy(build_stack(f, range_fn))
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-6)
})

test_that("a custom reducer cannot be distributed over spatial dims", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  spatial_mean <- function(x, dims) g_mean(x, dims = dims, nan_rm = TRUE)
  # A custom reducer has no algebraic partial/combine, so it cannot be split
  # across spatial chunks (unlike sum/mean/min/max/count). Over t it is fine.
  expect_error(
    execute_plan_mirai(plan_lazy(reduce_over(lazy_source(f), spatial_mean,
                                             c("x", "y")))),
    "spatial"
  )
})
