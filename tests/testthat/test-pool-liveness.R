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

test_that("a task whose daemon dies fails the wait instead of hanging it", {
  # a width-1 profile has no dispatcher, so the task never resolves
  local_pools(1, 1)
  prof <- garry:::.comp_profiles()[[1L]]
  h <- mirai::mirai(tools::pskill(Sys.getpid(), tools::SIGKILL), .compute = prof)
  t0 <- Sys.time()
  expect_error(garry:::.await_task(h, prof), "daemon")
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 30)
})

test_that("no wait outlives its daemon", {
  local_pools(1, 2)
  profs <- garry:::.comp_profiles()
  kill <- quote(tools::pskill(Sys.getpid(), tools::SIGKILL))
  # the broadcast loses its daemon, then every wait meets a dead pool
  expect_error(garry:::.pool_broadcast(kill, profiles = profs[[1L]]), "daemon")
  expect_error(garry:::.pool_broadcast(quote(1), profiles = profs[[1L]]), class = "garry_pool_error")
  expect_identical(garry:::.pool_broadcast(quote(1), profiles = profs[[1L]], live_only = TRUE), list())
  expect_error(garry:::.garry_pool_pids(profs[[1L]]), class = "garry_pool_error")
  state <- garry:::.garry_state
  state$abi_ok <- NULL
  expect_error(garry:::.garry_abi_check(profs[[1L]]), class = "garry_pool_error")
  # a live_only broadcast ends, whatever happens to its daemon
  expect_no_error(garry:::.pool_broadcast(kill, profiles = profs[[2L]], live_only = TRUE))
  # as does a failed run's cleanup of a dead writer
  h <- mirai::mirai(tools::pskill(Sys.getpid(), tools::SIGKILL), .compute = "garry_write")
  expect_no_error(garry:::.writer_settle(list(list(h = h))))
})

test_that("a reset connection reads as a lost daemon", {
  expect_match(
    garry:::.task_failure(structure(19L, class = "errorValue")),
    "daemon exited"
  )
  expect_identical(
    garry:::.task_failure(structure("boom", class = c("miraiError", "errorValue"))),
    "boom"
  )
})

test_that("a failed task reports what its daemon raised, in full", {
  local_pools(1, 0)
  h <- mirai::mirai(
    cli::cli_abort(
      c("read failed: a.tif.", "x" = "HTTP 403", "i" = "check the token"),
      class = c("garry_read_error", "garry_error"),
      call = NULL
    ),
    .compute = "garry_read"
  )
  v <- garry:::.await_task(h, "garry_read", lost = "return")
  why <- garry:::.task_failure(v)
  expect_match(why, "read failed", fixed = TRUE)
  expect_match(why, "HTTP 403", fixed = TRUE)
  expect_match(why, "check the token", fixed = TRUE)
  err <- expect_error(garry:::.task_abort("task s1_c1 failed on daemon", v), class = "garry_task_error")
  expect_s3_class(err, "garry_read_error")
  expect_match(conditionMessage(err), "HTTP 403", fixed = TRUE)
})

test_that("an unknown core count is said, not assumed in silence", {
  testthat::local_mocked_bindings(
    detectCores = function(...) NA_integer_,
    .package = "parallel"
  )
  rlang::reset_warning_verbosity("garry_cores_unknown")
  expect_warning(cr <- garry:::.garry_cores(), class = "garry_cores_warning")
  expect_identical(cr$logical, 4L)
})

test_that("a bare error value names itself", {
  expect_match(
    garry:::.task_failure(structure(7L, class = "errorValue")),
    "connection error 7",
    fixed = TRUE
  )
})

test_that("a daemon lost under a broadcast reports what the broadcast was for", {
  local_pools(1, 1)
  prof <- garry:::.comp_profiles()[[1L]]
  err <- expect_error(
    garry:::.pool_broadcast(
      quote(tools::pskill(Sys.getpid(), tools::SIGKILL)),
      profiles = prof,
      what = "closing the writer's outputs",
      class = "garry_write_error"
    ),
    class = "garry_write_error"
  )
  expect_match(conditionMessage(err), "closing the writer's outputs", fixed = TRUE)
  expect_s3_class(err, "garry_pool_error")
})

test_that("a writer lost between writes fails a read-only write, not a hang", {
  local_pools(1, 1)
  withr::local_options(garry.chunk_target_px = 300L)
  # more chunks than a reader's two in flight, so writes back up
  f <- tempfile(fileext = ".tif")
  ds <- gdalraster::create(
    "GTiff", f, 128L, 128L, 1L, "Float32",
    options = c("TILED=YES", "BLOCKXSIZE=16", "BLOCKYSIZE=16"),
    return_obj = TRUE
  )
  ds$setGeoTransform(c(500000, 30, 0, 5000000, 0, -30))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32633"))
  ds$write(1L, 0L, 0L, 128L, 128L, as.numeric(seq_len(128L^2)))
  ds$close()
  x <- lazy_source(f)
  expect_gt(nrow(garry:::chunk_iter(plan_lazy(x)@stages[[1L]]@chunks)), 8L)
  # the run's id is taken after its liveness check, before its first read
  testthat::local_mocked_bindings(
    .garry_run_id = function() {
      tools::pskill(garry:::.garry_pool_pids("garry_write"), tools::SIGKILL)
      for (i in 1:100) {
        if (garry:::.gd_n_compute("garry_write") == 0L) break
        Sys.sleep(0.05)
      }
      "gone"
    },
    .package = "garry"
  )
  t0 <- Sys.time()
  expect_error(write_tif(x, tempfile(fileext = ".tif"), distributed = TRUE), class = "garry_pool_error")
  expect_lt(as.numeric(difftime(Sys.time(), t0, units = "secs")), 30)
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

test_that("the read policy reaches the daemons on every route", {
  local_pools(1, 1)
  f <- fixture_gradient_f32()
  ask <- function(prof) {
    mirai::mirai(
      list(getOption("garry.read_retry"), getOption("garry.warp_exact")),
      .compute = prof
    )[]
  }
  withr::local_options(garry.read_retry = 7L, garry.warp_exact = TRUE)
  invisible(collect(lazy_source(f) * 2, distributed = TRUE)) # scheduler
  expect_identical(ask(garry:::.comp_profiles()[[1L]]), list(7L, TRUE))
  expect_identical(ask("garry_read"), list(7L, TRUE))
  withr::local_options(garry.read_retry = 8L, garry.warp_exact = FALSE)
  invisible(collect(lazy_source(f), distributed = TRUE)) # read only
  expect_identical(ask("garry_read"), list(8L, FALSE))
  withr::local_options(garry.read_retry = 9L)
  garry:::.gd_daemon_prep("garry_read") # the gdal-direct routes
  expect_identical(ask("garry_read"), list(9L, FALSE))
})

test_that("a broadcast task that fails stops the run, naming its cause", {
  local_pools(1, 1)
  prof <- garry:::.comp_profiles()
  err <- expect_error(
    garry:::.pool_broadcast(quote(stop("no policy here")), profiles = prof),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "no policy here", fixed = TRUE)
  # a broadcast that tolerates down daemons still reports a live one's error
  err <- expect_error(
    garry:::.pool_broadcast(quote(stop("live failure")), profiles = prof, live_only = TRUE),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "live failure", fixed = TRUE)
})

test_that("a pool that lost every daemon fails the run: it never moves to the host", {
  local_pools(1, 1)
  x <- lazy_source(fixture_gradient_f32()) * 2
  invisible(collect(x)) # the default route is the pools
  kill_all <- function(prof) {
    tools::pskill(garry:::.garry_pool_pids(prof), tools::SIGKILL)
    for (i in 1:100) {
      if (garry:::.gd_n_compute(prof) == 0L) break
      Sys.sleep(0.05)
    }
  }
  kill_all(garry:::.comp_profiles()[[1L]])
  expect_true(garry_daemons_set())
  expect_error(collect(x), class = "garry_pool_error")
  garry_daemons(1, 1, gdal_config = FALSE)
  kill_all("garry_read")
  expect_true(garry_daemons_set())
  expect_error(collect(x), class = "garry_pool_error")
  expect_error(collect(lazy_source(fixture_gradient_f32())), class = "garry_pool_error")
  garry_daemons(0, 0, gdal_config = FALSE)
  expect_false(garry_daemons_set())
  expect_no_error(collect(x)) # no pools at all: the host's own route
})

test_that("gdal_config = FALSE holds, and is about GDAL alone", {
  withr::local_envvar(MALLOC_MMAP_THRESHOLD_ = NA, MALLOC_TRIM_THRESHOLD_ = NA)
  local_pools(1, 1, gdal_config = FALSE)
  # the allocator defaults do not depend on the GDAL switch
  expect_identical(Sys.getenv("MALLOC_MMAP_THRESHOLD_"), "131072")
  ask <- function() {
    mirai::mirai(
      gdalraster::get_config_option("GDAL_DISABLE_READDIR_ON_OPEN"),
      .compute = "garry_read"
    )[]
  }
  garry:::.gd_daemon_prep("garry_read")
  expect_identical(ask(), "")
})

test_that("every daemon holds the GDAL cache size it was capped at", {
  withr::local_options(garry.gdal_cachemax_mb = 300)
  local_pools(1, 1)
  for (p in c("garry_read", garry:::.comp_profiles(), "garry_write")) {
    expect_identical(mirai::mirai(getOption("garry.gdal_cachemax_mb"), .compute = p)[], 300)
  }
})

test_that("garry_daemons validates its pool sizes", {
  expect_error(garry_daemons(NA, 1), "whole number")
  expect_error(garry_daemons(1, -1), "whole number")
  expect_error(garry_daemons(1, 1.5), "whole number")
  expect_error(garry_daemons(1, 1, read_handles = 0), ">= 1")
})
