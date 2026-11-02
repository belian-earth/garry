# A compute daemon that dies (an OOM kill, a crash) leaves its width-1
# profile registered with no daemon. The next distributed run must fail
# fast with a classed error, not block forever on its first broadcast.

skip_on_os("windows") # tools::pskill semantics

# These waits hang when they regress, so a regression must fail the test,
# not the suite. The limit is far above what they take on a loaded machine.
.local_wait_limit <- function(secs = 60, env = parent.frame()) {
  setTimeLimit(elapsed = secs)
  withr::defer(setTimeLimit(), envir = env)
}

test_that("no wait outlives its daemon", {
  local_pools(1, 3) # each death below spends a daemon
  .local_wait_limit()
  profs <- garry:::.comp_profiles()
  kill <- quote(tools::pskill(Sys.getpid(), tools::SIGKILL))
  # a width-1 profile has no dispatcher, so a task it lost never resolves
  h <- mirai::mirai(tools::pskill(Sys.getpid(), tools::SIGKILL), .compute = profs[[3L]])
  expect_error(garry:::.await_task(h, profs[[3L]]), "daemon")
  # the broadcast loses its daemon and says what it was for, then every
  # wait meets a dead pool
  err <- expect_error(
    garry:::.pool_broadcast(
      kill,
      profiles = profs[[1L]],
      what = "closing the writer's outputs",
      class = "garry_write_error"
    ),
    class = "garry_write_error"
  )
  expect_match(conditionMessage(err), "closing the writer's outputs", fixed = TRUE)
  expect_match(conditionMessage(err), "daemon", fixed = TRUE)
  expect_s3_class(err, "garry_pool_error")
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

test_that("an unknown core count is said, not assumed in silence", {
  testthat::local_mocked_bindings(
    detectCores = function(...) NA_integer_,
    .package = "parallel"
  )
  rlang::reset_warning_verbosity("garry_cores_unknown")
  withr::defer(rlang::reset_warning_verbosity("garry_cores_unknown"))
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

# One reader busy until `flag` exists, then dead: a broadcast sent before
# the flag goes up queues a task for it, which no daemon then takes. The
# flag orders the two, where a timer would leave it to the machine's load.
# The two tests that use this rest on mirai leaving that task queued: a
# mirai that hands it to a surviving daemon fails both.
.reader_dying_on <- function(flag) {
  h <- mirai::mirai(
    {
      while (!file.exists(flag)) {
        Sys.sleep(0.01)
      }
      tools::pskill(Sys.getpid(), tools::SIGKILL)
    },
    flag = flag,
    .compute = "garry_read"
  )
  while (mirai::status(.compute = "garry_read")$mirai[["executing"]] == 0L) {
    Sys.sleep(0.01)
  }
  h
}

test_that("a reader lost with a broadcast task queued for it ends the wait", {
  # Two readers stay connected, so a check for a live daemon passes while
  # the queue, and every run sent behind it, never moves.
  local_pools(3, 1)
  .local_wait_limit()
  x <- lazy_source(fixture_gradient_f32()) * 2
  flag <- tempfile()
  .reader_dying_on(flag)
  # the wait opens once every task of the broadcast has gone out
  real <- garry:::.idle_step
  testthat::local_mocked_bindings(
    .idle_step = function(...) {
      file.create(flag)
      real(...)
    },
    .package = "garry"
  )
  err <- expect_error(
    garry:::.pool_broadcast(quote(1), profiles = "garry_read", what = "the probe"),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "the probe failed", fixed = TRUE)
  expect_error(collect(x), class = "garry_pool_error")
  expect_no_error(garry_pool_hygiene())
})

test_that("a broadcast nobody waits for cannot strand the next wait", {
  # a run's region drops are sent and left, and a live_only broadcast
  # must end as an aborting one does
  local_pools(2, 0)
  .local_wait_limit()
  flag <- tempfile()
  busy <- .reader_dying_on(flag)
  mirai::everywhere(1, .compute = "garry_read")
  file.create(flag)
  while (mirai::unresolved(busy)) {
    Sys.sleep(0.01)
  }
  expect_identical(
    garry:::.pool_broadcast(quote(1), profiles = "garry_read", live_only = TRUE),
    list()
  )
  expect_identical(garry:::.gd_n_compute("garry_read"), 0L)
})

test_that("only a queue that stopped moving counts as stuck", {
  q <- function(awaiting, executing, completed) {
    c(awaiting = awaiting, executing = executing, completed = completed)
  }
  queue <- NULL
  reset <- character(0)
  testthat::local_mocked_bindings(
    status = function(.compute) list(mirai = queue),
    daemons = function(n, .compute) reset <<- c(reset, .compute),
    .package = "mirai"
  )
  check <- function(before, now) {
    queue <<- now
    garry:::.assert_pools_moving("p", list(p = before))
  }
  expect_identical(check(NULL, q(1L, 0L, 5L)), list(p = q(1L, 0L, 5L))) # a first look
  expect_no_error(check(q(1L, 1L, 5L), q(1L, 1L, 5L))) # a task running
  expect_no_error(check(q(1L, 1L, 5L), q(1L, 0L, 5L))) # it just ended
  expect_no_error(check(q(0L, 0L, 5L), q(0L, 0L, 5L))) # nothing queued
  expect_no_error(check(q(1L, 0L, 5L), q(1L, 0L, 6L))) # a task finished between checks
  expect_no_error(check(NULL, NULL)) # a width-1 profile has no queue
  expect_length(reset, 0L)
  # more tasks arriving does not make a stuck queue move
  expect_error(check(q(1L, 0L, 5L), q(2L, 0L, 5L)), class = "garry_pool_error")
  expect_identical(reset, "p")
})

test_that("a daemon lost between tasks fails the run's wait, not a hang", {
  local_pools(1, 1)
  testthat::local_mocked_bindings(.copy_args = function(...) NULL, .package = "garry") # the pool write
  withr::local_options(garry.chunk_target_px = 300L, garry.placement = "rules")
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
  # the run's id is taken after its liveness check, before its first task
  lose <- function(prof) {
    function() {
      tools::pskill(garry:::.garry_pool_pids(prof), tools::SIGKILL)
      for (i in 1:100) {
        if (garry:::.gd_n_compute(prof) == 0L) break
        Sys.sleep(0.05)
      }
      "gone"
    }
  }
  .local_wait_limit()
  testthat::with_mocked_bindings(
    expect_error(write_tif(x, tempfile(fileext = ".tif"), distributed = TRUE), class = "garry_pool_error"),
    .garry_run_id = lose("garry_write"),
    .package = "garry"
  )
  # a task sent to a dead width-1 profile never resolves, so only the
  # scheduler drain's own check ends this wait; a run with no write needs
  # no writer, so the loss above does not end it first
  testthat::with_mocked_bindings(
    expect_error(collect(x + 1, distributed = TRUE), class = "garry_pool_error"),
    .garry_run_id = lose(garry:::.comp_profiles()),
    .package = "garry"
  )
})

local({
  # unset, so that what the daemons hold is what their start exported
  withr::local_envvar(MALLOC_MMAP_THRESHOLD_ = NA, MALLOC_TRIM_THRESHOLD_ = NA)
  local_pools(2, 1)

  test_that("a failed task reports what its daemon raised, in full", {
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

  test_that("a distributed run leaves the RNG stream alone", {
    x <- lazy_source(fixture_gradient_f32()) * 2
    set.seed(42)
    before <- .Random.seed
    collect(x, distributed = TRUE)
    expect_identical(.Random.seed, before)
    expect_false(identical(garry:::.garry_run_id(), garry:::.garry_run_id()))
  })

  test_that("the read policy reaches the daemons on every route", {
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

  test_that("gdal_config = FALSE holds, and is about GDAL alone", {
    # the allocator defaults do not depend on the GDAL switch, and are read
    # at exec, so what counts is what a daemon started with
    expect_identical(
      mirai::mirai(Sys.getenv("MALLOC_MMAP_THRESHOLD_"), .compute = "garry_read")[],
      "131072"
    )
    ask <- function() {
      mirai::mirai(
        gdalraster::get_config_option("GDAL_DISABLE_READDIR_ON_OPEN"),
        .compute = "garry_read"
      )[]
    }
    garry:::.gd_daemon_prep("garry_read")
    expect_identical(ask(), "")
  })
})

test_that("a pool that lost a daemon, or all of them, fails the run: it never moves to the host", {
  local_pools(1, 2)
  .local_wait_limit()
  x <- lazy_source(fixture_gradient_f32()) * 2
  invisible(collect(x)) # the default route is the pools
  kill_all <- function(prof) {
    tools::pskill(garry:::.garry_pool_pids(prof), tools::SIGKILL)
    for (i in 1:100) {
      if (garry:::.gd_n_compute(prof) == 0L) break
      Sys.sleep(0.05)
    }
  }
  profs <- garry:::.comp_profiles()
  expect_length(garry:::.garry_pool_pids(profs[[1L]]), 1L)
  kill_all(profs[[1L]])
  expect_identical(garry:::.gd_n_compute(profs[[1L]]), 0L)
  expect_true(garry_daemons_set())
  expect_error(collect(x), class = "garry_pool_error")
  # hygiene skips the dead profile instead of hanging
  expect_no_error(garry_pool_hygiene())
  kill_all(profs[[2L]])
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

test_that("garry_daemons validates its pool sizes", {
  expect_error(garry_daemons(NA, 1), "whole number")
  expect_error(garry_daemons(1, -1), "whole number")
  expect_error(garry_daemons(1, 1.5), "whole number")
  expect_error(garry_daemons(1, 1, read_handles = 0), ">= 1")
})
