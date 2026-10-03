# A compute daemon that dies (an OOM kill, a crash) leaves its width-1
# profile registered with no daemon. The next distributed run must fail
# fast with a classed error, not block forever on its first broadcast.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")
skip_on_os("windows") # tools::pskill semantics

test_that("a dead compute daemon fails the next run fast and clearly", {
  local_pools(1, 2)
  x <- lazy_source(fixture_gradient_f32()) * 2
  expect_no_error(collect(x, distributed = TRUE))

  prof <- garry:::.comp_profiles()[[1L]]
  pid <- garry:::.garry_pool_pids(prof)
  skip_if(length(pid) != 1L, "routed width-1 profiles not in use")
  tools::pskill(pid, tools::SIGKILL)
  for (i in 1:100) {
    if (garry:::.gd_n_compute(prof) == 0L) break
    Sys.sleep(0.1)
  }
  expect_identical(garry:::.gd_n_compute(prof), 0L)

  t0 <- Sys.time()
  expect_error(collect(x, distributed = TRUE), class = "garry_pool_error")
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 30)
  # hygiene skips the dead profile instead of hanging
  expect_no_error(garry_pool_hygiene())
})

test_that("a distributed run leaves the RNG stream alone", {
  local_pools(1, 1)
  x <- lazy_source(fixture_gradient_f32()) * 2
  set.seed(42)
  before <- .Random.seed
  collect(x, distributed = TRUE)
  expect_identical(.Random.seed, before)
  expect_false(identical(garry:::.garry_run_id(), garry:::.garry_run_id()))
})

test_that("daemon-side options reach the daemons", {
  local_pools(1, 1)
  withr::local_options(garry.daemon_gc_mb = 777)
  invisible(collect(lazy_source(fixture_gradient_f32()) * 2, distributed = TRUE))
  got <- mirai::mirai(getOption("garry.daemon_gc_mb"), .compute = garry:::.comp_profiles()[[1L]])[]
  expect_identical(got, 777)
})

test_that("garry_daemons validates its pool sizes", {
  expect_error(garry_daemons(NA, 1), "whole number")
  expect_error(garry_daemons(1, -1), "whole number")
  expect_error(garry_daemons(1, 1.5), "whole number")
  expect_error(garry_daemons(1, 1, read_handles = 0), ">= 1")
  expect_error(garry_daemons(1, 1, dispatcher = TRUE), "set by")
})
