# garry never closes a pool while one of its daemons can still send a reply:
# that can hang the host for good (NNG's IPC close race, fixed in NNG 1.12.5
# and not yet in nanonext). A pool's close waits for what its daemons run, and
# a Ctrl-C or its deadline stops the daemons still mid-task. These tests
# assert those states; they do not try to hit the race.

skip_on_os("windows") # tools::pskill semantics

.local_wait_limit <- function(secs = 60, env = parent.frame()) {
  setTimeLimit(elapsed = secs)
  withr::defer(setTimeLimit(), envir = env)
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
  expect_match(msgs, "\"garry_read\" (2 running, pid", fixed = TRUE)
  expect_match(
    msgs,
    paste0("\"", comp, "\" (1 running, pid ", pids[[comp]], ")"),
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
      "Stopped 1 daemon still mid-task to close garry's pools: \"garry_read\" (1 running, pid ",
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
