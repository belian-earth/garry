# garry never closes a pool while one of its daemons can still send a reply:
# that can hang the host for good (NNG's IPC close race, fixed in NNG 1.12.5
# and not yet in nanonext). A pool's close waits for what its daemons run, and
# a Ctrl-C or its deadline stops the daemons still mid-task. A run waits for
# the store drops and closing clear it broadcasts, to the profiles that ran its
# tasks, and leaves a kernel warm-up on an idle compute daemon to the close. A
# failed run cancels the reads it gave up on, keeps its own error, and says
# once what failed in its cleanup. These tests assert those states; they do
# not try to hit the race.

skip_on_os("windows") # tools::pskill semantics

.local_wait_limit <- function(secs = 60, env = parent.frame()) {
  setTimeLimit(elapsed = secs)
  withr::defer(setTimeLimit(), envir = env)
}

# Every task handle the host sends while this is in force, through the two
# seams every launch goes through: runs' tasks (`warm` marks a kernel
# warm-up) and broadcasts.
.local_sent <- function(env = parent.frame()) {
  seen <- new.env(parent = emptyenv())
  seen$h <- list()
  real_task <- garry:::.task_mirai
  real_send <- garry:::.pool_send
  testthat::local_mocked_bindings(
    .task_mirai = function(.expr, ...) {
      h <- real_task(.expr, ...)
      warm <- grepl("warm", paste(deparse(.expr), collapse = " "), fixed = TRUE)
      seen$h <- c(
        seen$h,
        list(list(h = h, kind = if (warm) "warm" else "task"))
      )
      h
    },
    .pool_send = function(...) {
      s <- real_send(...)
      for (h in unlist(s, recursive = FALSE, use.names = FALSE)) {
        seen$h <- c(seen$h, list(list(h = h, kind = "broadcast")))
      }
      s
    },
    .package = "garry",
    .env = env
  )
  function(kind = c("task", "broadcast", "warm")) {
    Filter(function(x) x$kind %in% kind, seen$h)
  }
}

# Nothing of a run's own is unresolved, and the read pool and the writer
# run and queue nothing. A kernel warm-up on a compute daemon given no task
# may still compile: the pool's close waits for it.
.expect_quiet <- function(sent) {
  h <- lapply(sent(c("task", "broadcast")), `[[`, "h")
  expect_gt(length(h), 0L)
  expect_identical(sum(vapply(h, mirai::unresolved, logical(1))), 0L)
  for (p in c("garry_read", "garry_write")) {
    q <- mirai::status(.compute = p)$mirai
    expect_identical(
      unname(q[c("awaiting", "executing")]),
      c(0L, 0L),
      label = p
    )
  }
}

# Replace a daemon-side function of garry on every daemon of `prof`. The
# function sees `vars` and the daemon's global environment, no more.
.daemon_mock <- function(prof, name, fn, vars = list()) {
  environment(fn) <- list2env(vars, parent = globalenv())
  mirai::call_mirai(mirai::everywhere(
    {
      ns <- asNamespace("garry")
      unlockBinding(name, ns)
      assign(name, fn, envir = ns)
    },
    name = name,
    fn = fn,
    .compute = prof
  ))
  invisible(NULL)
}

# Hold `name` on the daemons of `profs` for `secs` before it runs.
.daemon_hold <- function(profs, name, secs) {
  for (p in profs) {
    mirai::call_mirai(mirai::everywhere(
      {
        ns <- asNamespace("garry")
        orig <- get(name, envir = ns)
        unlockBinding(name, ns)
        assign(
          name,
          function(...) {
            Sys.sleep(secs)
            orig(...)
          },
          envir = ns
        )
      },
      name = name,
      secs = secs,
      .compute = p
    ))
  }
  invisible(NULL)
}

.elapsed <- function(expr) {
  t0 <- Sys.time()
  force(expr)
  as.numeric(difftime(Sys.time(), t0, units = "secs"))
}

# Messages of class garry_pool_message `expr` emits, muffled.
.pool_messages <- function(expr) {
  msgs <- character(0)
  withCallingHandlers(
    expr,
    garry_pool_message = function(m) {
      msgs <<- c(msgs, gsub("\\s+", " ", conditionMessage(m)))
      invokeRestart("muffleMessage")
    }
  )
  msgs
}

# Whether process `pid` has exited (or is a zombie).
.pid_gone <- function(pid) {
  f <- file.path("/proc", pid, "stat")
  !file.exists(f) || grepl(") Z ", readLines(f, warn = FALSE), fixed = TRUE)
}

# Wait until no daemon of `prof` runs or queues a task.
.pool_drained <- function(prof) {
  repeat {
    q <- mirai::status(.compute = prof)$mirai
    if (q[["awaiting"]] == 0L && q[["executing"]] == 0L) {
      return(invisible(TRUE))
    }
    Sys.sleep(0.05)
  }
}

test_that("a run returns with nothing of its own in flight, on every route", {
  # five routes under a 60 s limit: covr's instrumented host runs past it on CI
  skip_on_covr()
  local_pools(2, 2)
  .local_wait_limit()
  # small chunks, and a read budget so small that every drop flushes as
  # soon as it is queued, mid-run
  withr::local_options(
    garry.chunk_target_px = 600,
    garry.read_target_px = 600,
    garry.read_budget_mb = 1e-6,
    garry.placement = "rules"
  )
  sent <- .local_sent()
  x <- lazy_source(fixture_gradient_f32())
  want <- .fixture_values(60, 40) * 2 + 1
  got <- collect(x * 2 + 1, distributed = TRUE)
  expect_identical(garry_last_route(), "scheduler")
  expect_equal(unclass(got), want, tolerance = 0, ignore_attr = TRUE)
  .expect_quiet(sent)
  out <- withr::local_tempfile(fileext = ".tif")
  write_tif(x * 2 + 1, out, distributed = TRUE)
  .expect_quiet(sent)
  expect_equal(
    gdal_read_window(out, 1L, 0L, 0L, 60L, 40L),
    want,
    ignore_attr = TRUE
  )
  collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "read_only")
  .expect_quiet(sent)
  testthat::local_mocked_bindings(
    .copy_args = function(...) NULL,
    .package = "garry"
  ) # the pool write
  write_tif(x, withr::local_tempfile(fileext = ".tif"), distributed = TRUE)
  .expect_quiet(sent)
  collect(.gg_masked_composite(), distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  .expect_quiet(sent)
  # the close waits for any warm-up left compiling: every task it sent
  # comes back with its own value, none with a closed connection's error
  garry_daemons(0, 0, gdal_config = FALSE)
  expect_false(garry_daemons_set())
  v <- lapply(sent(), function(x) x$h$data)
  expect_false(any(vapply(
    v,
    function(d) inherits(d, "errorValue"),
    logical(1)
  )))
})

test_that("a failed run keeps its error and drops the reads it left queued, on every route", {
  # the host must cancel within a read's 3 s sleep: covr's instrumented host may not
  skip_on_covr()
  local_pools(2, 1)
  .local_wait_limit()
  withr::local_options(
    garry.chunk_target_px = 100,
    garry.read_target_px = 100,
    garry.placement = "rules"
  )
  garry:::.garry_abi_check(c("garry_read", garry:::.comp_profiles()))
  mark <- withr::local_tempfile()
  ran <- function() {
    .pool_drained("garry_read")
    got <- Sys.glob(paste0(mark, "_*"))
    unlink(got)
    length(got)
  }
  # Each route's first read fails at once; every other read sleeps 3 s, the
  # time the host has to cancel, then leaves a mark. Four are in flight when
  # the first fails: the one on the other reader and the one its own reader
  # takes next run to their end, and the one queued behind them never
  # starts.
  sent <- .local_sent()
  .daemon_mock(
    "garry_read",
    ".daemon_run_source_shm",
    function(ra, cg, core, key, reg_key, ...) {
      if (grepl("_[cr]1$", reg_key)) {
        stop("read bomb on a daemon")
      }
      Sys.sleep(3)
      file.create(paste0(mark, "_", reg_key))
      NULL
    },
    vars = list(mark = mark)
  )
  x <- lazy_source(fixture_gradient_f32())
  err <- expect_error(
    collect(x + 1, distributed = TRUE),
    class = "garry_task_error"
  )
  expect_match(conditionMessage(err), "read bomb on a daemon", fixed = TRUE)
  .expect_quiet(sent)
  expect_identical(length(sent("task")), 4L)
  expect_identical(ran(), 2L)
  # the read-only route
  .daemon_mock(
    "garry_read",
    ".exec_read_padded",
    function(a, cg, core, ...) {
      if (core$y_off == 0 && core$x_off == 0) {
        stop("read bomb on a daemon")
      }
      Sys.sleep(3)
      file.create(paste0(mark, "_", core$y_off, "_", core$x_off))
      NULL
    },
    vars = list(mark = mark)
  )
  expect_error(collect(x, distributed = TRUE), "read bomb on a daemon")
  expect_identical(garry_last_route(), "read_only")
  expect_identical(ran(), 2L)
  # the composite route: its mask reads fail once all have landed, with two
  # of its four band reads running and two queued behind them
  .daemon_mock(
    "garry_read",
    ".cd_fetch_warp",
    function(j, k) {
      if (grepl("-fmask", j$bin, fixed = TRUE)) {
        stop("mask bomb on a daemon")
      }
      Sys.sleep(3)
      file.create(paste0(mark, "_", basename(j$bin)))
      NULL
    },
    vars = list(mark = mark)
  )
  expect_error(
    collect(.gg_masked_composite(), distributed = TRUE),
    "mask bomb on a daemon"
  )
  expect_identical(garry_last_route(), "composite_direct")
  # A queued band read can start before the cancel lands on a slow host
  # (R-devel on CI started 3 of the 4), and then runs to its end; without the
  # cancel all 4 run.
  expect_lt(ran(), 4L)
})

test_that("a failed cleanup is said once, and the run's error stays its own, whatever warn is", {
  local_pools(1, 1)
  .local_wait_limit()
  withr::local_options(garry.placement = "rules")
  garry:::.garry_abi_check(c("garry_read", garry:::.comp_profiles()))
  .daemon_mock("garry_read", ".daemon_run_source_shm", function(...) {
    stop("read bomb on a daemon")
  })
  .daemon_mock("garry_read", ".daemon_shm_clear", function() {
    stop("clear bomb {on} a daemon")
  })
  sent <- .local_sent()
  x <- lazy_source(fixture_gradient_f32()) + 1
  for (w in c(0L, 2L)) {
    old <- options(warn = w)
    err <- NULL
    msgs <- .pool_messages(tryCatch(
      withCallingHandlers(
        collect(x, distributed = TRUE),
        warning = function(w) stop("a warning became an error")
      ),
      error = function(e) err <<- e
    ))
    options(old)
    expect_s3_class(err, "garry_task_error")
    expect_match(conditionMessage(err), "read bomb on a daemon", fixed = TRUE)
    expect_length(msgs, 1L)
    expect_match(msgs, "could not clean up after the run", fixed = TRUE)
    expect_match(msgs, "clear bomb {on} a daemon", fixed = TRUE)
    expect_match(msgs, "garry_read", fixed = TRUE)
    .expect_quiet(sent)
  }
})

test_that("a run's guard finishes a run that returns and fails one that does not", {
  calls <- character(0)
  store <- list(
    finish = function() calls <<- c(calls, "finish"),
    fail = function() calls <<- c(calls, "fail")
  )
  expect_identical(
    withVisible(garry:::.run_guard(invisible(2), store)),
    list(value = 2, visible = FALSE)
  )
  expect_identical(calls, c("finish", "fail")) # fail() is a no-op once finished
  # the caller receives the run's own error, and the cleanup has run by then
  calls <- character(0)
  got <- tryCatch(
    garry:::.run_guard(
      cli::cli_abort("run {.val bomb}", class = "k_error"),
      store
    ),
    k_error = function(e) list(e, calls)
  )
  expect_match(conditionMessage(got[[1L]]), "run \"bomb\"", fixed = TRUE)
  expect_identical(got[[2L]], "fail")
  calls <- character(0)
  got <- tryCatch(
    garry:::.run_guard(rlang::interrupt(), store),
    interrupt = function(i) calls
  )
  expect_identical(got, "fail")
})

test_that("closing the pools waits for what runs, and names the daemons it waits on", {
  local_pools(2, 1)
  .local_wait_limit()
  testthat::local_mocked_bindings(
    .pools_close_s = function() c(say = 0.3, kill = 60),
    .package = "garry"
  )
  marks <- replicate(4, tempfile())
  hold <- function(f, prof) {
    garry:::.task_mirai(
      quote({
        Sys.sleep(1.5)
        file.create(f)
      }),
      f = f,
      .compute = prof
    )
  }
  # two reads running, one queued behind them, and a compute task
  h <- list(hold(marks[[1L]], "garry_read"), hold(marks[[2L]], "garry_read"))
  h[[3L]] <- hold(marks[[3L]], "garry_read")
  comp <- garry:::.comp_profiles()[[1L]]
  h[[4L]] <- hold(marks[[4L]], comp)
  while (mirai::status(.compute = "garry_read")$mirai[["executing"]] < 2L) {
    Sys.sleep(0.01)
  }
  pids <- garry:::.garry_state$prof_pids
  took <- .elapsed(
    msgs <- .pool_messages(garry_daemons(0, 0, gdal_config = FALSE))
  )
  expect_gt(took, 2.5)
  expect_length(msgs, 1L)
  expect_match(
    msgs,
    paste0(
      "\"garry_read\" (pid ",
      paste(pids$garry_read, collapse = ", "),
      ")"
    ),
    fixed = TRUE
  )
  expect_match(
    msgs,
    paste0("\"", comp, "\" (pid ", pids[[comp]], ")"),
    fixed = TRUE
  )
  expect_match(msgs, "Press Ctrl-C", fixed = TRUE)
  # nothing was stopped: every task ran to its end, the queued one too,
  # and each came back with its own value
  expect_true(all(file.exists(marks)))
  expect_true(all(vapply(h, function(x) isTRUE(x$data), logical(1))))
  expect_false(garry_daemons_set())
})

test_that("a close waits for its probes, not only for a dispatcher's count", {
  # the close must finish inside its 3 s notice: covr's instrumented host may not
  skip_on_covr()
  local_pools(1, 1)
  .local_wait_limit()
  h <- garry:::.task_mirai(
    quote({
      Sys.sleep(1)
      TRUE
    }),
    .compute = "garry_read"
  )
  while (mirai::status(.compute = "garry_read")$mirai[["executing"]] < 1L) {
    Sys.sleep(0.01)
  }
  # the dispatcher reports nothing running for half a second, as it does
  # before it has assigned a probe it was just sent
  real <- mirai::status
  t_end <- Sys.time() + 0.5
  testthat::local_mocked_bindings(
    status = function(.compute = NULL) {
      s <- real(.compute = .compute)
      if (identical(.compute, "garry_read") && Sys.time() < t_end) {
        s$mirai[c("awaiting", "executing")] <- 0L
      }
      s
    },
    .package = "mirai"
  )
  msgs <- .pool_messages(garry_daemons(0, 0, gdal_config = FALSE))
  expect_length(msgs, 0L)
  expect_true(h$data)
})

test_that("a close stops the daemons still mid-task at its deadline, and only those", {
  local_pools(2, 1)
  .local_wait_limit()
  testthat::local_mocked_bindings(
    .pools_close_s = function() c(say = 0.2, kill = 1),
    .package = "garry"
  )
  # a reader stopped mid-task, and an idle compute daemon stopped
  f <- tempfile()
  mirai::mirai(
    {
      writeLines(as.character(Sys.getpid()), f)
      Sys.sleep(30)
    },
    f = f,
    .compute = "garry_read"
  )
  while (!file.exists(f) || !length(readLines(f))) {
    Sys.sleep(0.01)
  }
  reader <- as.integer(readLines(f))
  pids <- garry:::.garry_state$prof_pids
  other <- setdiff(pids$garry_read, reader)
  comp <- pids[[garry:::.comp_profiles()[[1L]]]]
  tools::pskill(c(reader, comp), tools::SIGSTOP)
  withr::defer(tools::pskill(c(reader, comp), tools::SIGKILL))
  took <- .elapsed(
    msgs <- .pool_messages(garry_daemons(0, 0, gdal_config = FALSE))
  )
  expect_gt(took, 1)
  expect_lt(took, 5)
  expect_length(msgs, 2L)
  expect_match(msgs[[2L]], "Stopped 2 daemons still mid-task", fixed = TRUE)
  expect_match(msgs[[2L]], paste("pid", reader), fixed = TRUE)
  expect_match(msgs[[2L]], paste("pid", comp), fixed = TRUE)
  expect_false(grepl(paste0("\\b", other, "\\b"), msgs[[2L]]))
  expect_true(.pid_gone(reader))
  expect_true(.pid_gone(comp))
  expect_false(garry_daemons_set())
  expect_identical(garry:::.gd_n_compute("garry_read"), 0L)
})

test_that("a Ctrl-C during a close stops the daemons still mid-task, closes, and stops garry_daemons()", {
  local_pools(2, 1)
  .local_wait_limit()
  testthat::local_mocked_bindings(
    .pools_close_s = function() c(say = 0.2, kill = 60),
    .package = "garry"
  )
  # a reader in a task that never ends and cannot be interrupted
  f <- tempfile()
  mirai::mirai(
    {
      writeLines(as.character(Sys.getpid()), f)
      suspendInterrupts(
        repeat {
          for (i in 1:100) {
            NULL
          }
        }
      )
    },
    f = f,
    .compute = "garry_read"
  )
  while (!file.exists(f) || !length(readLines(f))) {
    Sys.sleep(0.01)
  }
  spin <- as.integer(readLines(f))
  withr::defer(tools::pskill(spin, tools::SIGKILL))
  msgs <- character(0)
  took <- .elapsed(
    got <- tryCatch(
      withCallingHandlers(
        garry_daemons(2, 1, gdal_config = FALSE),
        garry_pool_message = function(m) {
          msgs <<- c(msgs, gsub("\\s+", " ", conditionMessage(m)))
          if (length(msgs) == 1L) {
            tools::pskill(Sys.getpid(), tools::SIGINT) # the user's Ctrl-C
          }
          invokeRestart("muffleMessage")
        }
      ),
      interrupt = function(i) "interrupted"
    )
  )
  expect_identical(got, "interrupted")
  expect_lt(took, 5)
  expect_length(msgs, 2L)
  expect_match(
    msgs[[2L]],
    paste0(
      "Stopped 1 daemon still mid-task to close garry's pools: \"garry_read\" (pid ",
      spin,
      ")"
    ),
    fixed = TRUE
  )
  expect_true(.pid_gone(spin))
  # closed, and no pool started after the Ctrl-C
  expect_false(garry_daemons_set())
  expect_identical(garry:::.gd_n_compute("garry_read"), 0L)
})

# A reader in a task that never ends and cannot be interrupted; its pid.
.spin_reader <- function(env = parent.frame()) {
  f <- tempfile()
  mirai::mirai(
    {
      writeLines(as.character(Sys.getpid()), f)
      suspendInterrupts(
        repeat {
          for (i in 1:100) {
            NULL
          }
        }
      )
    },
    f = f,
    .compute = "garry_read"
  )
  while (!file.exists(f) || !length(readLines(f))) {
    Sys.sleep(0.01)
  }
  spin <- as.integer(readLines(f))
  withr::defer(tools::pskill(spin, tools::SIGKILL), envir = env)
  spin
}

test_that("a close stops no daemon lost before it, nor a process that took its pid", {
  local_pools(2, 1)
  .local_wait_limit()
  testthat::local_mocked_bindings(
    .pools_close_s = function() c(say = 0.2, kill = 1),
    .package = "garry"
  )
  # a reader lost, its pid now another process's: a daemon of a pool garry
  # does not own, which the close sends no probe
  mirai::daemons(1L, dispatcher = FALSE, .compute = "decoy")
  withr::defer(mirai::daemons(0L, .compute = "decoy"))
  decoy <- mirai::call_mirai(mirai::mirai(
    Sys.getpid(),
    .compute = "decoy"
  ))$data
  lost <- garry:::.garry_state$prof_pids$garry_read[[1L]]
  tools::pskill(lost, tools::SIGKILL)
  while (garry:::.gd_n_compute("garry_read") > 1L) {
    Sys.sleep(0.01)
  }
  state <- garry:::.garry_state
  state$prof_pids$garry_read[[1L]] <- decoy
  spin <- .spin_reader()
  msgs <- .pool_messages(garry_daemons(0, 0, gdal_config = FALSE))
  expect_length(msgs, 2L)
  expect_match(
    msgs[[1L]],
    paste0("\"garry_read\" (pid ", spin, ")"),
    fixed = TRUE
  )
  expect_match(
    msgs[[2L]],
    paste0(
      "Stopped 1 daemon still mid-task to close garry's pools: \"garry_read\" (pid ",
      spin,
      ")"
    ),
    fixed = TRUE
  )
  expect_true(.pid_gone(spin))
  expect_identical(
    mirai::call_mirai(mirai::mirai(Sys.getpid(), .compute = "decoy"))$data,
    decoy
  )
  expect_false(garry_daemons_set())
})

test_that("a close that can stop no daemon of a pool still mid-task fails, naming the pool", {
  local_pools(1, 1)
  .local_wait_limit()
  testthat::local_mocked_bindings(
    .pools_close_s = function() c(say = 0.2, kill = 1),
    .package = "garry"
  )
  spin <- .spin_reader()
  # as a start interrupted before it recorded its pids leaves the pool
  state <- garry:::.garry_state
  state$prof_pids$garry_read <- integer(0)
  err <- expect_error(
    .pool_messages(garry_daemons(0, 0, gdal_config = FALSE)),
    class = "garry_pool_error"
  )
  expect_match(
    conditionMessage(err),
    "\"garry_read\" (no daemon garry can stop)",
    fixed = TRUE
  )
  expect_false(garry_daemons_set())
  tools::pskill(spin, tools::SIGKILL)
  while (garry:::.gd_n_compute("garry_read") > 0L) {
    Sys.sleep(0.01)
  }
  expect_no_error(garry_daemons(0, 0, gdal_config = FALSE))
  expect_identical(garry:::.gd_n_compute("garry_read"), 0L)
})

test_that("a failed run's clear spares a compute task still reading its input", {
  local_pools(2, 1)
  .local_wait_limit()
  withr::local_options(
    garry.chunk_target_px = 600,
    garry.read_target_px = 600,
    garry.placement = "rules"
  )
  comp <- garry:::.comp_profiles()
  garry:::.garry_abi_check(c("garry_read", comp))
  # the first read lands and its compute task is held 1.5 s; every other
  # read fails at 0.3 s. The readers' clear, sent before the compute daemon
  # is done with what was queued for it, took that daemon down.
  .daemon_mock(
    "garry_read",
    ".daemon_run_source_shm",
    function(ra, cg, core, key, reg_key, ...) {
      if (!grepl("_[cr]1$", reg_key)) {
        Sys.sleep(0.3)
        stop("read bomb on a daemon")
      }
      real(ra, cg, core, key, reg_key, ...)
    },
    vars = list(real = garry:::.daemon_run_source_shm)
  )
  .daemon_hold(comp, ".daemon_run_compute_shm", 1.5)
  x <- lazy_source(fixture_gradient_f32()) * 2 + 1
  msgs <- .pool_messages(expect_error(
    collect(x, distributed = TRUE),
    "read bomb on a daemon"
  ))
  expect_length(msgs, 0L)
  expect_identical(garry:::.gd_n_compute(comp), 1L)
  expect_no_error(garry:::.assert_pools_alive(c("garry_read", comp)))
})

test_that("a failed run's clear spares a compute task queued for another compute daemon's output", {
  local_pools(1, 2)
  .local_wait_limit()
  comp <- garry:::.comp_profiles()
  # an upstream output, pinned on the first compute daemon as a compute task
  # pins its own
  up <- garry:::.task_mirai(
    quote({
      sh <- mori::share(stats::setNames(list(as.raw(rep(1:250, 400))), "k"))
      reg <- asNamespace("garry")$.daemon_shm
      reg[["r9_s2_c1"]] <- sh
      sh
    }),
    .compute = comp[[1L]]
  )
  v <- mirai::call_mirai(up)$data
  # on the second, a task running and the downstream task queued behind it:
  # received after the first daemon's clear, its input would be gone, and the
  # daemon with it
  garry:::.task_mirai(quote(Sys.sleep(1.5)), .compute = comp[[2L]])
  Sys.sleep(0.2)
  down <- garry:::.task_mirai(
    quote(sum(as.integer(v[["k"]]))),
    v = v,
    .compute = comp[[2L]]
  )
  store <- garry:::.store_broadcasts(comp)
  msgs <- .pool_messages(store$fail())
  expect_length(msgs, 0L)
  expect_identical(mirai::call_mirai(down)$data, sum(rep(1:250, 400)))
  expect_identical(garry:::.gd_n_compute(comp[[2L]]), 1L)
})

test_that("a failed run cancels its own tasks and never a broadcast's", {
  # the drop must still queue when the read fails: under covr's slower host it has
  # already run, so no broadcast is in flight to spare
  skip_on_covr()
  local_pools(2, 1)
  .local_wait_limit()
  withr::local_options(
    garry.chunk_target_px = 300,
    garry.read_target_px = 300,
    garry.read_budget_mb = 1e-6,
    garry.placement = "rules"
  )
  garry:::.garry_abi_check(c("garry_read", garry:::.comp_profiles()))
  # the first read lands at once, so its region's drop goes out while the
  # rest still read, and queues behind them; the second fails after it
  .daemon_mock(
    "garry_read",
    ".daemon_run_source_shm",
    function(ra, cg, core, key, reg_key, ...) {
      if (grepl("_[cr]2$", reg_key)) {
        Sys.sleep(0.5)
        stop("read bomb on a daemon")
      }
      if (!grepl("_[cr]1$", reg_key)) {
        Sys.sleep(3)
      }
      real(ra, cg, core, key, reg_key, ...)
    },
    vars = list(real = garry:::.daemon_run_source_shm)
  )
  sent <- .local_sent()
  hs <- function(kind) lapply(sent(kind), `[[`, "h")
  stopped <- list()
  open_casts <- 0L
  real_stop <- mirai::stop_mirai
  testthat::local_mocked_bindings(
    stop_mirai = function(x) {
      open <- vapply(hs("broadcast"), mirai::unresolved, logical(1))
      open_casts <<- max(open_casts, sum(open))
      stopped <<- c(stopped, if (is.list(x)) x else list(x))
      real_stop(x)
    },
    .package = "mirai"
  )
  err <- expect_error(
    collect(lazy_source(fixture_gradient_f32()) + 1, distributed = TRUE),
    class = "garry_task_error"
  )
  expect_match(conditionMessage(err), "read bomb on a daemon", fixed = TRUE)
  # a broadcast was in flight to be cancelled, and was not
  expect_gt(open_casts, 0L)
  expect_gt(length(stopped), 0L)
  is_in <- function(x, set) any(vapply(set, identical, logical(1), x))
  expect_true(all(vapply(stopped, is_in, logical(1), hs("task"))))
  expect_false(any(vapply(stopped, is_in, logical(1), hs("broadcast"))))
})

test_that("a task that landed uncollected after its region was freed stops no failure or close", {
  local_pools(2, 1)
  .local_wait_limit()
  withr::local_options(garry.placement = "rules")
  garry:::.garry_abi_check(c("garry_read", garry:::.comp_profiles()))
  # a read task's reply as the scheduler leaves one after a failed run: it
  # landed after the last harvest, and the run's clear freed its region
  h <- garry:::.task_mirai(
    quote({
      sh <- mori::share(stats::setNames(
        list(matrix(stats::rnorm(1e5), 100)),
        "k"
      ))
      reg <- asNamespace("garry")$.daemon_shm
      reg[["r0_s1_c1"]] <- sh
      sh
    }),
    .compute = "garry_read"
  )
  .pool_drained("garry_read")
  Sys.sleep(0.5)
  garry:::.pool_broadcast(
    quote(asNamespace("garry")$.daemon_shm_clear()),
    "garry_read"
  )
  garry:::.pool_broadcast(quote(invisible(gc())), "garry_read")
  expect_error(mirai::unresolved(h), "shared memory region not found")
  # a failing composite run returns its own error
  .daemon_mock("garry_read", ".cd_fetch_warp", function(j, k) stop("warp bomb"))
  expect_error(collect(.gg_masked_composite(), distributed = TRUE), "warp bomb")
  # a scheduler run still runs, and the pools still close
  x <- lazy_source(fixture_gradient_f32())
  expect_equal(
    unclass(collect(x * 2, distributed = TRUE)),
    .fixture_values(60, 40) * 2,
    tolerance = 0,
    ignore_attr = TRUE
  )
  expect_no_error(garry_daemons(0, 0, gdal_config = FALSE))
  expect_false(garry_daemons_set())
})

test_that("a run waits for no warm-up on a compute daemon it gave no task", {
  local_pools(1, 3)
  .local_wait_limit(180)
  testthat::local_mocked_bindings(
    .pools_close_s = function() c(say = 0.3, kill = 60),
    .package = "garry"
  )
  withr::local_options(
    garry.placement = "rules",
    garry.chunk_target_px = 1e6,
    garry.read_target_px = 1e6
  )
  x <- lazy_source(fixture_gradient_f32())
  # warm every daemon's XLA client, time a run of a new kernel with nothing
  # held, then hold the next kernel's warm-up on the profiles that will get
  # no task (the one task goes to the first). The hold is at least three
  # times that run, so a run that waited on it would take the hold, past
  # the bound, on a runner of any speed.
  invisible(collect(x * 2 + 1, distributed = TRUE))
  base <- .elapsed(collect(x * 4 + 3, distributed = TRUE))
  hold <- max(6, 3 * base)
  comps <- garry:::.comp_profiles()
  .daemon_hold(comps[-1L], ".daemon_warm_jit", hold)
  tlog <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.task_log = tlog)
  took <- .elapsed(got <- collect(x * 3 + 2, distributed = TRUE))
  expect_equal(
    unclass(got),
    .fixture_values(60, 40) * 3 + 2,
    tolerance = 0,
    ignore_attr = TRUE
  )
  d <- utils::read.csv(tlog)
  slots <- unique(d$slot[
    d$event == "launch" & d$pool == "comp" & !startsWith(d$key, "warm")
  ])
  expect_identical(slots, comps[[1L]])
  expect_lt(took, base + hold / 2)
  # the close waits for the warm-ups the run left compiling
  expect_message(
    garry_daemons(1, 4, gdal_config = FALSE),
    paste0("\"", comps[[2L]], "\"\\s+\\(pid "),
    class = "garry_pool_message"
  )
  # the composite route leaves its warm-ups the same way: one strip each
  # for the mask and two bands, so the fourth daemon gets none
  withr::local_options(garry.gd_strips = 1L, garry.task_log = NULL)
  invisible(collect(.gg_masked_composite(), distributed = TRUE))
  base <- .elapsed(collect(.gg_masked_composite(), distributed = TRUE))
  hold <- max(6, 3 * base)
  comps <- garry:::.comp_profiles()
  .daemon_hold(comps[[4L]], ".gd_warm_pipeline", hold)
  took <- .elapsed(collect(.gg_masked_composite(), distributed = TRUE))
  expect_identical(garry_last_route(), "composite_direct")
  expect_lt(took, base + hold / 2)
  expect_message(
    garry_daemons(0, 0, gdal_config = FALSE),
    paste0("\"", comps[[4L]], "\"\\s+\\(pid "),
    class = "garry_pool_message"
  )
})

test_that("a daemon lost under a broadcast fails it, naming the pool", {
  local_pools(1, 1)
  .local_wait_limit()
  err <- expect_error(
    garry:::.pool_broadcast(
      quote(tools::pskill(Sys.getpid(), tools::SIGKILL)),
      profiles = "garry_read",
      what = "the probe"
    ),
    class = "garry_pool_error"
  )
  expect_match(conditionMessage(err), "the probe failed on", fixed = TRUE)
  expect_match(conditionMessage(err), "garry_read", fixed = TRUE)
  # a store drop's reset connection (error value 19) fails the run at the
  # next drop, naming the pool
  garry_daemons(1, 1, gdal_config = FALSE)
  .daemon_mock("garry_read", ".daemon_shm_drop", function(keys) {
    tools::pskill(Sys.getpid(), tools::SIGKILL)
  })
  sent <- .local_sent()
  store <- garry:::.store_broadcasts("garry_read")
  store$drop("r0_s1_c1")
  h <- sent("broadcast")[[1L]]$h
  while (mirai::unresolved(h)) {
    Sys.sleep(0.01)
  }
  expect_identical(as.integer(h$data), 19L)
  err <- expect_error(store$drop("r0_s1_c2"), class = "garry_pool_error")
  expect_match(
    conditionMessage(err),
    "releasing the run's shared memory failed on",
    fixed = TRUE
  )
  expect_match(conditionMessage(err), "garry_read", fixed = TRUE)
  expect_match(conditionMessage(err), "daemon exited", fixed = TRUE)
  # the pool is down now: a failed run's cleanup leaves it to the next run
  expect_silent(store$fail())
  expect_error(
    garry:::.assert_pools_alive("garry_read"),
    class = "garry_pool_error"
  )
})
