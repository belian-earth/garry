# Per-daemon measured-memory correction: refresh_mem_budgets polls the
# fleet's anonymous RSS (/proc/<pid>/status RssAnon, pids recorded at
# pool creation) and tightens the compute budget when measurement
# exceeds the modelled working sets, so an estimate defect becomes a
# throughput dip and a log line instead of an OOM.

test_that(".garry_fleet_anon_mb measures live pids and NAs otherwise", {
  skip_on_os(c("windows", "mac"))
  own <- garry:::.garry_fleet_anon_mb(Sys.getpid())
  expect_true(is.finite(own) && own > 0)
  expect_true(is.na(garry:::.garry_fleet_anon_mb(integer(0))))
})

test_that("a measured RSS spike tightens the budget; the run still completes", {
  skip_on_os(c("windows", "mac"))
  local_pools(2, 1)
  # First sample (the run-start baseline) is modest; every later sample
  # is a 10 TB spike: RECENT growth, which must tighten. A constant
  # huge reading would instead be absorbed by the baseline/trailing
  # window (sustained retained memory is tolerated by design).
  n <- 0L
  testthat::local_mocked_bindings(
    .garry_fleet_anon_mb = function(pids) {
      n <<- n + 1L
      if (n == 1L) 1000 else 1e7
    },
    .package = "garry")
  f <- fixture_gradient_f32()
  expect_message(
    got <- collect(lazy_source(f) + 1, distributed = TRUE),
    "compute budget tightened")
  expect_equal(unclass(got), .fixture_values(60, 40) + 1, tolerance = 0, ignore_attr = TRUE)
})
