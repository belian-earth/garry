# A daemon that dies (an OOM kill, a crash) fails the tasks it held as it
# goes, and leaves its profile registered short of a daemon. The next
# distributed run must fail fast with a classed error, and no wait on a task
# sent to the dead daemon may block forever.

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
  # the task its daemon died under fails as lost
  h <- garry:::.pool_submit(profs[[3L]], kill)
  expect_error(garry:::.await_task(h, profs[[3L]]), "daemon exited")
  # one sent to the dead daemon never runs, and the width check ends its wait
  h <- garry:::.pool_submit(profs[[3L]], quote(1))
  expect_error(garry:::.await_task(h, profs[[3L]]), class = "garry_pool_error")
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
  h <- garry:::.pool_submit("garry_write", kill)
  expect_no_error(garry:::.writer_settle(list(list(h = h))))
})

test_that("a failed task says why: its daemon's error, or why it was lost", {
  expect_match(
    garry:::.task_failure(garry:::.task_lost_value("its daemon exited, probably killed (out of memory?)")),
    "daemon exited"
  )
  expect_identical(garry:::.task_failure(garry:::.task_raised_value(simpleError("boom"))), "boom")
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

# One reader held busy until the host kills it, by its pid. The pid file
# orders the two, where a timer would leave it to the machine's load.
.reader_held <- function() {
  f <- tempfile()
  garry:::.pool_submit(
    "garry_read",
    quote({
      writeLines(as.character(Sys.getpid()), paste0(f, ".tmp"))
      file.rename(paste0(f, ".tmp"), f)
      repeat {
        Sys.sleep(0.01)
      }
    }),
    list(f = f)
  )
  while (!file.exists(f)) {
    Sys.sleep(0.01)
  }
  as.integer(readLines(f))
}

test_that("a reader killed mid-broadcast fails the broadcast, and the pool stays down", {
  local_pools(3, 1)
  .local_wait_limit()
  x <- lazy_source(fixture_gradient_f32()) * 2
  pid <- .reader_held()
  sent <- garry:::.pool_send(quote(1), "garry_read")
  tools::pskill(pid, tools::SIGKILL)
  # its probe was queued behind the read it died in, so it never runs: the
  # width check ends the wait in about a second
  err <- expect_error(
    garry:::.pool_await(sent, what = "the probe"),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "the probe failed on", fixed = TRUE)
  expect_match(conditionMessage(err), "garry_read", fixed = TRUE)
  expect_match(conditionMessage(err), "2 of its 3", fixed = TRUE)
  # the other readers took theirs
  took <- vapply(sent$garry_read[-1L], function(h) {
    while (garry:::.task_unresolved(h)) Sys.sleep(0.01)
    identical(h$data, 1)
  }, logical(1))
  expect_true(all(took))
  expect_identical(garry:::.gd_n_compute("garry_read"), 2L)
  err <- expect_error(
    garry:::.pool_broadcast(quote(1), profiles = "garry_read"),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "2 of its 3", fixed = TRUE)
  expect_identical(
    garry:::.pool_broadcast(quote(1), profiles = "garry_read", live_only = TRUE),
    list()
  )
  expect_error(collect(x), class = "garry_pool_error")
  expect_no_error(garry_pool_hygiene())
})

test_that("a pool short of the daemons it started with fails the check", {
  state <- garry:::.garry_state
  old <- state$prof_pids
  withr::defer(state$prof_pids <- old)
  state$prof_pids <- list(r = 1:3, c1 = 4L)
  have <- c(r = 3L, c1 = 1L, x = 0L)
  testthat::local_mocked_bindings(
    .gd_n_compute = function(prof) have[[prof]],
    .package = "garry"
  )
  expect_no_error(garry:::.assert_pools_alive(c("r", "c1")))
  have[["r"]] <- 2L
  err <- expect_error(
    garry:::.assert_pools_alive(c("r", "c1")),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "\"r\" has 2 of its 3", fixed = TRUE)
  have[["c1"]] <- 0L
  err <- expect_error(
    garry:::.assert_pools_alive(c("r", "c1")),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "2 garry daemon pools", fixed = TRUE)
  expect_match(conditionMessage(err), "\"c1\" has 0 of its 1", fixed = TRUE)
  # a pool garry did not start passes with any daemon, and fails with none
  expect_error(
    garry:::.assert_pools_alive("x"),
    "\"x\" has none",
    class = "garry_pool_error"
  )
  have[["x"]] <- 1L
  expect_no_error(garry:::.assert_pools_alive("x"))
  expect_identical(
    garry:::.pools_down(c("r", "c1", "x"))$down,
    c(TRUE, TRUE, FALSE)
  )
})

test_that("a pool that lost one of its daemons fails the next run at its start", {
  local_pools(2, 1)
  .local_wait_limit()
  x <- lazy_source(fixture_gradient_f32()) * 2
  tools::pskill(garry:::.garry_pool_pids("garry_read")[[1L]], tools::SIGKILL)
  while (garry:::.gd_n_compute("garry_read") == 2L) {
    Sys.sleep(0.01)
  }
  err <- expect_error(collect(x), class = "garry_pool_error")
  expect_match(conditionMessage(err), "garry_read", fixed = TRUE)
  expect_match(conditionMessage(err), "1 of its 2", fixed = TRUE)
  expect_true(garry_daemons_set())
})

test_that("a daemon lost between tasks fails the run's wait, not a hang", {
  local_pools(1, 1)
  testthat::local_mocked_bindings(.copy_args = function(...) NULL, .package = "garry") # the pool write
  withr::local_options(
    garry.chunk_target_px = 300L, garry.read_target_px = 300L, garry.placement = "rules"
  )
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
  spec <- garry:::.read_only_spec(plan_lazy(x), distributed = TRUE)
  expect_gt(nrow(garry:::chunk_iter(spec$read_stage[[1L]]@chunks)), 8L)
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
    h <- garry:::.pool_submit(
      "garry_read",
      quote(cli::cli_abort(
        c("read failed: a.tif.", "x" = "HTTP 403", "i" = "check the token"),
        class = c("garry_read_error", "garry_error"),
        call = NULL
      ))
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
      .on_daemon(
        list(getOption("garry.read_retry"), getOption("garry.warp_exact")),
        .compute = prof
      )
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
      .on_daemon(Sys.getenv("MALLOC_MMAP_THRESHOLD_"), .compute = "garry_read"),
      "131072"
    )
    # and they reach glibc's own tunables, which a mizu worker's start does
    # not override (it raises the thresholds unless malloc is tuned there)
    if (.Platform$OS.type == "unix") {
      expect_identical(
        .on_daemon(Sys.getenv("GLIBC_TUNABLES"), .compute = "garry_read"),
        "glibc.malloc.mmap_threshold=131072:glibc.malloc.trim_threshold=131072"
      )
    }
    ask <- function() {
      .on_daemon(
        gdalraster::get_config_option("GDAL_DISABLE_READDIR_ON_OPEN"),
        .compute = "garry_read"
      )
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

test_that("a task carries its expression and no source text", {
  # Wherever source is kept (R CMD check, covr, load_all()) a function
  # literal in a task's wrapper would carry garry's source text, about
  # 4 MB, into every task.
  testthat::local_mocked_bindings(
    .pool_submit = function(prof, expr, args = list(), member = NULL) expr,
    .package = "garry"
  )
  for (timed in c(FALSE, TRUE)) {
    e <- garry:::.task_submit(
      quote(1 + 1),
      .compute = "garry_read",
      .timed = timed
    )
    expect_lt(length(serialize(e, NULL)), 1e4)
  }
})

test_that("a cancel lets a running task run to its end, and drops one queued", {
  local_pools(1, 0)
  .local_wait_limit()
  f <- tempfile()
  g <- tempfile()
  task <- quote({
    t0 <- Sys.time()
    while (difftime(Sys.time(), t0, units = "secs") < 1) {
      for (i in 1:100) {
        NULL
      }
    }
    file.create(f)
  })
  h <- garry:::.task_submit(task, f = f, .compute = "garry_read")
  q <- garry:::.task_submit(task, f = g, .compute = "garry_read")
  while (.pool_counts("garry_read")[["running"]] < 1L) {
    Sys.sleep(0.01)
  }
  garry:::.task_cancel(list(h, q))
  .pool_drained("garry_read")
  expect_true(file.exists(f))
  expect_false(file.exists(g))
  expect_false(garry:::.task_unresolved(h))
  expect_s3_class(h$data, "garry_task_lost")
  expect_s3_class(q$data, "garry_task_lost")
  expect_identical(.on_daemon(3, .compute = "garry_read"), 3)
})

test_that("a reader group holds tasks on the host, two a reader, and lands them all", {
  local_pools(2, 0)
  .local_wait_limit()
  g <- garry:::.pool_record("garry_read")
  hs <- lapply(1:7, function(i) {
    garry:::.task_submit(quote({
      Sys.sleep(0.2)
      i * 10
    }), i = i, .compute = "garry_read")
  })
  expect_identical(g$load, c(2L, 2L))
  expect_length(g$queue, 3L)
  # a host-held task cancels without reaching a daemon
  garry:::.task_cancel(hs[7L])
  expect_length(g$queue, 2L)
  expect_s3_class(hs[[7L]]$data, "garry_task_lost")
  got <- vapply(hs[1:6], function(h) garry:::.await_task(h, "garry_read"), numeric(1))
  expect_identical(got, (1:6) * 10)
  expect_identical(g$load, c(0L, 0L))
  expect_length(g$queue, 0L)
  # a broadcast reaches each reader, outside the group's depth
  expect_length(unique(unlist(.everywhere(Sys.getpid(), .compute = "garry_read"))), 2L)
})

test_that("a daemon past its cap holds the rest on the host, in order, and cancels them there", {
  local_pools(1, 1)
  .local_wait_limit()
  prof <- garry:::.comp_profiles()[[1L]]
  g <- garry:::.pool_record(prof)
  cap <- garry:::.member_cap
  f <- tempfile()
  n <- cap + 12L
  hs <- lapply(seq_len(n), function(i) {
    garry:::.task_submit(quote({
      Sys.sleep(0.01)
      cat(i, "\n", file = f, append = TRUE)
      i
    }), i = i, f = f, .compute = prof)
  })
  expect_length(g$launched[[1L]], cap)
  expect_length(g$backlog[[1L]], 12L)
  # one held on the host cancels there and never runs
  garry:::.task_cancel(hs[n])
  expect_length(g$backlog[[1L]], 11L)
  expect_s3_class(hs[[n]]$data, "garry_task_lost")
  got <- vapply(hs[-n], function(h) garry:::.await_task(h, prof), numeric(1))
  expect_identical(got, as.numeric(seq_len(n - 1L)))
  expect_identical(as.integer(readLines(f)), seq_len(n - 1L))
  expect_length(g$launched[[1L]], 0L)
  expect_length(g$backlog[[1L]], 0L)
})

test_that("a cancel that comes after the task finished lands it, and frees its reader", {
  local_pools(2, 0)
  .local_wait_limit()
  g <- garry:::.pool_record("garry_read")
  h <- garry:::.task_submit(quote(6 * 7), .compute = "garry_read")
  .pool_drained("garry_read")
  expect_identical(g$load, c(1L, 0L)) # not polled yet
  garry:::.task_cancel(list(h))
  expect_identical(h$data, 42)
  expect_identical(g$load, c(0L, 0L))
  expect_length(g$launched[[1L]], 0L)
})

test_that("on Linux a daemon whose process has gone is down, whatever mizu reports", {
  skip_if_not(dir.exists("/proc/self"), "garry reads processes from /proc")
  local_pools(1, 1)
  prof <- garry:::.comp_profiles()[[1L]]
  expect_identical(garry:::.gd_n_compute(prof), 1L)
  testthat::local_mocked_bindings(.pid_ours = function(pid, dir) FALSE, .package = "garry")
  expect_identical(garry:::.gd_n_compute(prof), 0L)
  expect_error(garry:::.assert_pools_alive(prof), class = "garry_pool_error")
})

test_that("an interrupt at a daemon, as a Ctrl-C at the host's terminal sends, ends no task", {
  local_pools(1, 0)
  .local_wait_limit()
  f <- tempfile()
  h <- garry:::.task_submit(
    quote({
      writeLines(as.character(Sys.getpid()), f)
      Sys.sleep(1)
      "ran to its end"
    }),
    f = f,
    .compute = "garry_read"
  )
  while (!file.exists(f) || !length(readLines(f))) {
    Sys.sleep(0.01)
  }
  tools::pskill(as.integer(readLines(f)), tools::SIGINT)
  expect_identical(garry:::.await_task(h, "garry_read"), "ran to its end")
  expect_identical(garry:::.gd_n_compute("garry_read"), 1L)
  expect_identical(.on_daemon(3, .compute = "garry_read"), 3)
})

test_that("a daemon that cannot start fails garry_daemons(), and no daemon is left", {
  .local_wait_limit()
  testthat::local_mocked_bindings(
    .pool_join = function(f) {
      mizu::mizu_pool(1L, startup_timeout = 0.5, launcher = function(token, slot) NULL)
    },
    .package = "garry"
  )
  dir <- NULL
  real <- garry:::.pools_spawn
  testthat::local_mocked_bindings(
    .pools_spawn = function(files) {
      dir <<- dirname(files[[1L]])
      real(files)
    },
    .package = "garry"
  )
  err <- expect_error(garry_daemons(1, 1, gdal_config = FALSE), class = "garry_pool_error")
  expect_match(conditionMessage(err), "did not start", fixed = TRUE)
  expect_false(garry_daemons_set())
  expect_false(dir.exists(dir))
  # every daemon the start spawned has exited
  Sys.sleep(1)
  pids <- as.integer(basename(Sys.glob("/proc/[0-9]*")))
  left <- pids[vapply(pids, garry:::.pid_ours, logical(1), dir = dir)]
  expect_length(left, 0L)
})
