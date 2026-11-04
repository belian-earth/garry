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

# One reader held busy until the host kills it, by its pid: a broadcast
# sent while it is held queues its last task for it, and no surviving reader
# may take that task (nanonext's sync generation). The pid file orders the
# two, where a timer would leave it to the machine's load.
.reader_held <- function() {
  f <- tempfile()
  mirai::mirai(
    {
      writeLines(as.character(Sys.getpid()), paste0(f, ".tmp"))
      file.rename(paste0(f, ".tmp"), f)
      repeat {
        Sys.sleep(0.01)
      }
    },
    f = f,
    .compute = "garry_read"
  )
  while (!file.exists(f)) {
    Sys.sleep(0.01)
  }
  as.integer(readLines(f))
}

test_that("a reader killed mid-broadcast strands the dispatcher, and the width check ends the wait", {
  local_pools(3, 1)
  .local_wait_limit()
  x <- lazy_source(fixture_gradient_f32()) * 2
  pid <- .reader_held()
  # the wait opens once every task of the broadcast has gone out: the
  # held reader dies then, and the wait counts its idle steps
  killed <- FALSE
  steps <- 0L
  real <- garry:::.idle_step
  testthat::local_mocked_bindings(
    .idle_step = function(...) {
      if (!killed) {
        killed <<- TRUE
        tools::pskill(pid, tools::SIGKILL)
      }
      step <- real(...)
      function() {
        steps <<- steps + 1L
        step()
      }
    },
    .package = "garry"
  )
  err <- expect_error(
    garry:::.pool_broadcast(quote(1), profiles = "garry_read", what = "the probe"),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "the probe failed", fixed = TRUE)
  expect_match(conditionMessage(err), "garry_read", fixed = TRUE)
  expect_match(conditionMessage(err), "2 of its 3", fixed = TRUE)
  # one check a second, and a step sleeps 2 ms or more: about 500 steps
  expect_lt(steps, 1500L)
  # the strand is there: the last task queued, nothing running, and the
  # pool a daemon short, which is what the check reads
  s <- mirai::status(.compute = "garry_read")
  expect_identical(s$connections, 2L)
  expect_identical(s$mirai[["awaiting"]], 1L)
  expect_identical(s$mirai[["executing"]], 0L)
  expect_error(collect(x), class = "garry_pool_error")
  expect_no_error(garry_pool_hygiene())
})

test_that("a stranded pool is left out of live-only work and refused by the rest", {
  local_pools(2, 0)
  .local_wait_limit()
  pid <- .reader_held()
  sent <- mirai::everywhere(1, .compute = "garry_read")
  while (mirai::unresolved(sent[[1L]])) {
    Sys.sleep(0.01) # the sync task, on the other reader
  }
  tools::pskill(pid, tools::SIGKILL)
  while (garry:::.gd_n_compute("garry_read") == 2L) {
    Sys.sleep(0.01)
  }
  expect_identical(
    garry:::.pool_broadcast(quote(1), profiles = "garry_read", live_only = TRUE),
    list()
  )
  err <- expect_error(
    garry:::.pool_broadcast(quote(1), profiles = "garry_read"),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "1 of its 2", fixed = TRUE)
  expect_true(mirai::unresolved(sent[[2L]])) # queued for good
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

test_that("only a queue that stopped moving at full width counts as stuck, and it stays down", {
  state <- garry:::.garry_state
  old <- list(state$pool_stuck, state$prof_pids)
  withr::defer({
    state$pool_stuck <- old[[1L]]
    state$prof_pids <- old[[2L]]
  })
  state$pool_stuck <- NULL
  state$prof_pids <- list(p = 1:3)
  q <- function(awaiting, executing, completed) {
    c(awaiting = awaiting, executing = executing, completed = completed)
  }
  queue <- NULL
  closed <- character(0)
  testthat::local_mocked_bindings(
    status = function(.compute) list(connections = 3L, mirai = queue),
    daemons = function(n, .compute) closed <<- c(closed, .compute),
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
  expect_null(state$pool_stuck)
  # more tasks arriving does not make a stuck queue move
  err <- expect_error(
    check(q(1L, 0L, 5L), q(2L, 0L, 5L)),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "\"p\" takes no more tasks", fixed = TRUE)
  expect_match(conditionMessage(err), "garry_daemons", fixed = TRUE)
  # the pool is not closed inside the wait, and it stays down
  expect_length(closed, 0L)
  expect_identical(state$pool_stuck, "p")
  expect_error(
    garry:::.assert_pools_alive("p"),
    "takes no more tasks",
    class = "garry_pool_error"
  )
  expect_true(garry:::.pools_down("p")$down)
})

.elapsed <- function(expr) {
  t0 <- Sys.time()
  force(expr)
  as.numeric(difftime(Sys.time(), t0, units = "secs"))
}

test_that("a broadcast's send runs to its end through an interrupt", {
  local_pools(2, 0)
  .local_wait_limit()
  real <- mirai::everywhere
  sent_whole <- FALSE
  busy <- function(secs) {
    t0 <- Sys.time()
    while (difftime(Sys.time(), t0, units = "secs") < secs) {
      for (i in 1:100) {
        NULL
      }
    }
  }
  testthat::local_mocked_bindings(
    everywhere = function(...) {
      # an interrupt arrives once the send has begun
      tools::pskill(Sys.getpid(), tools::SIGINT)
      busy(0.2)
      out <- do.call(real, list(...))
      sent_whole <<- TRUE
      out
    },
    .package = "mirai"
  )
  r <- tryCatch(
    {
      garry:::.pool_send(quote(1), "garry_read")
      busy(0.2)
      "no interrupt"
    },
    interrupt = function(i) "interrupted"
  )
  expect_true(sent_whole)
  expect_identical(r, "interrupted")
  # the generation closed: the pool still takes broadcasts and tasks
  testthat::local_mocked_bindings(everywhere = real, .package = "mirai")
  expect_no_error(garry:::.pool_broadcast(quote(2), profiles = "garry_read"))
  expect_identical(mirai::mirai(3, .compute = "garry_read")[], 3)
})

test_that("a broadcast left unfinished at full width fails the wait in seconds, and the pool stays down", {
  local_pools(3, 1)
  .local_wait_limit(30)
  x <- lazy_source(fixture_gradient_f32()) * 2
  # one reader busy while a broadcast goes out, so its last task queues for
  # that reader; then that task is cancelled, which garry never does, and
  # its sync generation stays open with every reader connected
  f <- tempfile()
  busy <- mirai::mirai(
    {
      writeLines("x", f)
      Sys.sleep(1.5)
      1
    },
    f = f,
    .compute = "garry_read"
  )
  while (!file.exists(f)) {
    Sys.sleep(0.01)
  }
  ev <- mirai::everywhere(Sys.sleep(0.05), .compute = "garry_read")
  while (mirai::unresolved(ev[[1L]]) || mirai::unresolved(ev[[2L]])) {
    Sys.sleep(0.01)
  }
  expect_true(mirai::stop_mirai(ev[[3L]]))
  mirai::call_mirai(busy)
  took <- .elapsed(
    err <- expect_error(
      garry:::.pool_broadcast(
        quote(1),
        profiles = "garry_read",
        what = "the probe"
      ),
      class = "garry_pool_error"
    )
  )
  expect_lt(took, 6)
  expect_match(
    gsub("\\s+", " ", conditionMessage(err)),
    "\"garry_read\" takes no more tasks",
    fixed = TRUE
  )
  expect_identical(garry:::.gd_n_compute("garry_read"), 3L)
  # every later run fails at its start, with no wait, until a restart
  took <- .elapsed(expect_error(collect(x), class = "garry_pool_error"))
  expect_lt(took, 0.5)
  expect_no_error(garry_pool_hygiene())
  garry_daemons(3, 1, gdal_config = FALSE)
  expect_no_error(collect(x))
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

test_that("a task carries its expression and no source text", {
  # Wherever source is kept (R CMD check, covr, load_all()) a function
  # literal in a task's wrapper would carry garry's source text, about
  # 4 MB, into every task.
  testthat::local_mocked_bindings(
    mirai = function(.expr, ...) .expr,
    .package = "mirai"
  )
  for (timed in c(FALSE, TRUE)) {
    e <- garry:::.task_mirai(
      quote(1 + 1),
      .compute = "garry_read",
      .timed = timed
    )
    expect_lt(length(serialize(e, NULL)), 1e4)
  }
})

test_that("a cancel lets a running task run to its end", {
  local_pools(1, 0)
  .local_wait_limit()
  f <- tempfile()
  h <- garry:::.task_mirai(
    quote({
      t0 <- Sys.time()
      while (difftime(Sys.time(), t0, units = "secs") < 1) {
        for (i in 1:100) {
          NULL
        }
      }
      file.create(f)
    }),
    f = f,
    .compute = "garry_read"
  )
  while (mirai::status(.compute = "garry_read")$mirai[["executing"]] < 1L) {
    Sys.sleep(0.01)
  }
  expect_true(mirai::stop_mirai(h))
  repeat {
    q <- mirai::status(.compute = "garry_read")$mirai
    if (q[["executing"]] == 0L && q[["awaiting"]] == 0L) {
      break
    }
    Sys.sleep(0.05)
  }
  expect_true(file.exists(f))
  expect_identical(mirai::mirai(3, .compute = "garry_read")[], 3)
})
