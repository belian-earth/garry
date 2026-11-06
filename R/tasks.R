#' @include options.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# garry's task layer over mizu pools (design/mizu-pools.md).
#
# Every daemon is a single-worker mizu pool, so the host reaches each one by
# name: broadcasts, the store's drops, per-daemon kernel warmth and liveness
# all address a daemon. A profile names one or more daemons. "garry_read" is
# the reader group and "garry_comp_<i>" and "garry_write" are a daemon each. A
# task goes to a profile. A group holds its tasks on the host until one of its
# daemons has fewer than `depth` running or queued, the least loaded first, so
# a reader never idles while reads wait and no more than one read queues behind
# a running one. A single-daemon profile takes each task as it is submitted:
# the scheduler routes compute itself. Past `.member_cap` tasks out on one
# daemon, its tasks wait on the host in order.
#
# A task's handle is an environment: `state` is "queued" (on the host),
# "launched" or "done", and `data` holds the value once done, or a failure
# value: garry_task_raised when the task raised (the daemon's condition, its
# classes and fields intact), garry_task_lost when it can never return one
# (its daemon died, it was cancelled, or its pool stopped).
# ---------------------------------------------------------------------------

# Profile records by name: `members` (mizu pool handles), `depth` (Inf for a
# single-daemon profile), `queue` (host-held handles, FIFO), `routed` (by
# member, the queued tasks it launched and has not seen land) and `load`.
.garry_pools <- new.env(parent = emptyenv())

# mizu pool shape for one garry daemon. One submitter: the host. The rings and
# result slots bound what one daemon holds at once (two routed tasks and the
# broadcasts behind them), and a slot of 4 KB carries a daemon's error with
# cli's bullets whole. A task or result past a slot travels in a region of its
# own. The rings and slots are 1 MB of shared memory a daemon.
.pool_shape <- list(
  max_submitters = 1L,
  injection_cap = 64L,
  per_worker_cap = 64L,
  result_slots = 128L,
  slot_size = 4096L
)

# Tasks sent to one daemon and not yet landed, at most. Past it a daemon's tasks
# wait on the host, in order (.member_put()), so its ring never fills and its
# result slots never run out: a writer behind its queue of writes, or a compute
# daemon in a long compile collecting the store's drops, takes them in turn.
.member_cap <- 48L

# Seconds a pool waits for its daemon to join, and a submission for room in a
# daemon's ring, which `.member_cap` keeps from filling. A daemon joins once R
# and mizu have started, so either one running out means something is wrong.
.pool_join_s <- 60
.pool_submit_s <- 60

# A profile's record, or NULL when it has none.
.pool_record <- function(prof) {
  if (exists(prof, envir = .garry_pools, inherits = FALSE)) {
    get(prof, envir = .garry_pools, inherits = FALSE)
  }
}

# Daemons of profile `prof` that are running. mizu frees a dead daemon's slot
# as soon as the kernel reports its exit, through a death watch it cannot set
# up everywhere (Linux's pidfd_open() can be missing or refused, as under some
# sandboxes), so on Linux a daemon whose process has gone counts as dead too.
.pool_live <- function(prof) {
  g <- .pool_record(prof)
  if (is.null(g)) {
    return(0L)
  }
  proc <- !is.null(g$pids) && dir.exists("/proc/self")
  sum(vapply(
    seq_along(g$members),
    function(i) {
      identical(mizu::mizu_pool_info(g$members[[i]])$workers, "live") &&
        (!proc || .pid_ours(g$pids[[i]], g$dir))
    },
    logical(1)
  ))
}

# ---- launch -----------------------------------------------------------------

# Hex form of a string for argv, as the daemon script reads it.
.hex <- function(x) paste(charToRaw(enc2utf8(x)), collapse = "")

# The library paths daemons load packages from: the host's own, so a daemon
# runs the garry the host loaded. Under covr, the instrumented library is left
# out when a clean garry is on the path: covr bakes a trace-file finalizer into
# the instrumented package, and a daemon hitting the (benign) XLA teardown
# segfault leaves a truncated trace that aborts covr's merge ("error reading
# from connection", diagnosed 2026-08-12). Daemons then run the installed garry:
# identical formals, so the ABI token passes, and no trace files. Daemon code is
# uncounted in coverage; the single-process equivalence tests run the same logic
# on the host, where it is counted.
.daemon_lib_paths <- function(libs = .libPaths()) {
  if (!identical(Sys.getenv("R_COVR"), "true")) {
    return(libs)
  }
  # By content, not find.package(): under testthat::test_local() the host garry
  # is pkgload-loaded from the source tree, so find.package() points there while
  # covr's instrumented install still sits first on the lib path (diagnosed
  # 2026-08-12). An instrumented install carries the save hook
  # covr:::add_hooks() writes into the package load script.
  instrumented <- function(lib) {
    ls_ <- file.path(lib, "garry", "R", "garry")
    file.exists(ls_) &&
      any(grepl(
        "covr:::save_trace",
        tryCatch(readLines(ls_, warn = FALSE), error = function(e) {
          character(0)
        }),
        fixed = TRUE
      ))
  }
  bad <- vapply(libs, instrumented, logical(1))
  clean <- libs[!bad]
  has_garry <- file.exists(file.path(clean, "garry", "R", "garry"))
  if (!any(bad) || !any(has_garry)) {
    return(libs)
  }
  clean
}

# The environment daemons start with, on top of the host's. glibc's malloc
# thresholds must be set at exec (.garry_env_defaults()), and a mizu worker
# raises them to 32 and 128 MB at start unless GLIBC_TUNABLES already tunes
# malloc: garry's thresholds go there too, so freed buffers still return to
# the OS. Unix only: system2() sets no environment on Windows, which has no
# glibc.
.daemon_env <- function() {
  if (.Platform$OS.type != "unix") {
    return(character(0))
  }
  tun <- Sys.getenv("GLIBC_TUNABLES")
  if (grepl("glibc.malloc", tun, fixed = TRUE)) {
    return(character(0))
  }
  mine <- .glue(
    "glibc.malloc.mmap_threshold={Sys.getenv('MALLOC_MMAP_THRESHOLD_', '131072')}",
    ":glibc.malloc.trim_threshold={Sys.getenv('MALLOC_TRIM_THRESHOLD_', '131072')}"
  )
  .glue(
    "GLIBC_TUNABLES={shQuote(paste(c(if (nzchar(tun)) tun, mine), collapse = ':'))}"
  )
}

# Start a daemon process for each of token files `files` at once
# (inst/scripts/garry-daemon.R), each waiting for the token of the pool it will
# join. Their directory names the generation in every daemon's command line.
.pools_spawn <- function(files) {
  script <- system.file(
    "scripts",
    "garry-daemon.R",
    package = "garry",
    mustWork = TRUE
  )
  rscript <- file.path(
    R.home("bin"),
    if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
  )
  libs <- vapply(.daemon_lib_paths(), .hex, character(1), USE.NAMES = FALSE)
  env <- .daemon_env()
  for (f in files) {
    system2(
      rscript,
      c(shQuote(script), .hex(f), libs),
      env = env,
      wait = FALSE,
      stdout = FALSE,
      stderr = FALSE
    )
  }
  invisible(files)
}

# The mizu pool for the daemon waiting on token file `f`: its launcher hands the
# pool's token to that daemon.
.pool_join <- function(f) {
  hand <- function(token, slot) {
    tmp <- paste0(f, ".tmp")
    writeLines(c(token, as.character(slot)), tmp)
    file.rename(tmp, f)
    invisible(NULL)
  }
  do.call(
    mizu::mizu_pool,
    c(
      list(n_workers = 1L),
      .pool_shape,
      list(startup_timeout = .pool_join_s, launcher = hand)
    )
  )
}

# Start the profiles `sizes` names (profile -> daemon count) and record them;
# `depth` is the routed depth of a group of more than one daemon. Every daemon
# starts at once and joins its pool in turn, so a generation takes about one R
# start-up, not one per daemon. A daemon that does not join fails the start,
# and the daemons already up stop with it, as they do on an interrupt.
.pools_start <- function(sizes, depth) {
  sizes <- sizes[sizes > 0L]
  if (!length(sizes)) {
    return(invisible(NULL))
  }
  dir <- tempfile("garry-pool-")
  dir.create(dir)
  files <- file.path(dir, .glue("d{seq_len(sum(sizes))}"))
  made <- list()
  ok <- FALSE
  on.exit(
    if (!ok) {
      for (m in made) {
        suppressWarnings(mizu::mizu_pool_stop(m, timeout = 0))
      }
      .pid_kill(.pid_files(files), dir)
      unlink(dir, recursive = TRUE) # a daemon not yet joined exits with it
    },
    add = TRUE
  )
  .pools_spawn(files)
  owner <- rep(names(sizes), sizes)
  pools <- tryCatch(
    lapply(files, function(f) {
      m <- .pool_join(f)
      made[[length(made) + 1L]] <<- m
      m
    }),
    mizu_error_startup = function(e) {
      secs <- .pool_join_s
      cli::cli_abort(
        c(
          "a garry daemon did not start within {secs} s.",
          "x" = "{conditionMessage(e)}",
          "i" = "Check that {.code Rscript} runs here and loads {.pkg mizu} from {.path {(.libPaths())[[1L]]}}."
        ),
        class = c("garry_pool_error", "garry_error"),
        call = NULL
      )
    }
  )
  for (p in names(sizes)) {
    g <- new.env(parent = emptyenv())
    g$members <- pools[owner == p]
    n <- length(g$members)
    g$depth <- if (n > 1L) as.integer(depth) else Inf
    g$queue <- list()
    g$backlog <- rep(list(list()), n)
    g$launched <- rep(list(list()), n)
    g$load <- integer(n)
    g$pids <- NULL
    g$dir <- dir
    assign(p, g, envir = .garry_pools)
  }
  ok <- TRUE
  invisible(NULL)
}

# The pids the daemons of token files `files` wrote, those that started.
.pid_files <- function(files) {
  pf <- paste0(files, ".pid")
  pf <- pf[file.exists(pf)]
  as.integer(unlist(lapply(pf, readLines, warn = FALSE)))
}

# SIGKILL the processes `pids` that still run a daemon of the generation in
# `dir` (their command line names it): a pid may since belong to another
# process.
.pid_kill <- function(pids, dir) {
  ours <- pids[vapply(pids, .pid_ours, logical(1), dir = dir)]
  if (length(ours)) {
    tools::pskill(ours, tools::SIGKILL)
  }
  invisible(ours)
}

# Does process `pid` still run a daemon of the generation in `dir`? A process
# that has exited, a zombie included, has no command line.
.pid_ours <- function(pid, dir) {
  grepl(.hex(file.path(dir, "d")), .pid_cmdline(pid), fixed = TRUE)
}

# ---- tasks ------------------------------------------------------------------

.task_seq <- function() {
  n <- (.garry_state$task_seq %||% 0L) + 1L
  .garry_state$task_seq <- n
  n
}

# A task's failure values (see the top of this file).
.task_raised_value <- function(cnd) {
  structure(
    list(condition = cnd),
    class = c("garry_task_raised", "garry_task_failure")
  )
}

.task_lost_value <- function(why, cnd = NULL) {
  structure(
    list(why = why, condition = cnd),
    class = c("garry_task_lost", "garry_task_failure")
  )
}

# Submit QUOTED expression `expr` with named data `args` to profile `prof`,
# without waiting. `member` sends it to that daemon of the profile, ahead of
# the group's queue and outside its depth: a broadcast. Returns the handle.
.pool_submit <- function(prof, expr, args = list(), member = NULL) {
  g <- .pool_record(prof)
  if (is.null(g)) {
    cli::cli_abort(
      "garry has no daemon pool {.val {prof}}: call {.fn garry_daemons} first.",
      class = c("garry_pool_error", "garry_error"),
      call = NULL
    )
  }
  h <- new.env(parent = emptyenv())
  h$id <- .task_seq()
  h$prof <- prof
  # Daemons share the host's process group, so a Ctrl-C at its terminal
  # interrupts them too, and an interrupt mid-task would end the daemon: its
  # worker catches errors only, and mizu turns interrupts back on to run a
  # task. A task resumes through one and runs to its end. The handler lives on
  # the daemon: a function literal here would carry its srcref, and with it
  # garry's source text, about 4 MB in every task wherever source is kept
  # (covr, R CMD check, load_all()).
  h$expr <- bquote(asNamespace("garry")$.daemon_resumable(.(expr)))
  h$args <- args
  h$state <- "queued"
  h$data <- NULL
  h$rec <- g
  h$member <- NULL
  h$routed <- FALSE
  if (!is.null(member)) {
    .member_put(g, member, h, routed = FALSE)
  } else if (is.finite(g$depth)) {
    g$queue[[length(g$queue) + 1L]] <- h
    .group_launch(g)
  } else {
    .member_put(g, 1L, h, routed = FALSE)
  }
  h
}

# Give handle `h` to daemon `i` of record `g`: sent now, or held in the
# daemon's backlog, in order, while `.member_cap` of its tasks are out.
.member_put <- function(g, i, h, routed) {
  h$member <- i
  h$routed <- routed
  if (routed) {
    g$load[[i]] <- g$load[[i]] + 1L
  }
  if (length(g$backlog[[i]]) || length(g$launched[[i]]) >= .member_cap) {
    g$backlog[[i]][[length(g$backlog[[i]]) + 1L]] <- h
  } else {
    .member_send(g, i, h)
  }
  invisible(h)
}

# Send handle `h` to daemon `i` of record `g`. A send that fails leaves the
# handle lost, and fails the caller.
.member_send <- function(g, i, h) {
  h$task <- tryCatch(
    do.call(
      mizu::mizu_submit,
      c(
        list(.pool = g$members[[i]], .expr = h$expr),
        h$args,
        list(.timeout = .pool_submit_s)
      )
    ),
    mizu_error = function(e) {
      h$data <- .task_lost_value("it could not be sent", e)
      h$state <- "done"
      if (h$routed) {
        g$load[[i]] <- g$load[[i]] - 1L
      }
      cli::cli_abort(
        c(
          "cannot send a task to garry pool {.val {h$prof}}.",
          "x" = "{conditionMessage(e)}"
        ),
        class = c("garry_pool_error", "garry_error"),
        parent = e,
        call = NULL
      )
    }
  )
  h$state <- "launched"
  h$expr <- NULL
  h$args <- NULL
  g$launched[[i]][[length(g$launched[[i]]) + 1L]] <- h
  invisible(h)
}

# A sent task of handle `h` has landed, or was cancelled: its daemon has room
# for one more, from its backlog.
.member_landed <- function(h) {
  g <- h$rec
  i <- h$member
  r <- g$launched[[i]]
  g$launched[[i]] <- r[
    !vapply(r, function(x) identical(x$id, h$id), logical(1))
  ]
  if (h$routed) {
    g$load[[i]] <- g$load[[i]] - 1L
  }
  if (!isTRUE(g$closed)) {
    while (length(g$backlog[[i]]) && length(g$launched[[i]]) < .member_cap) {
      b <- g$backlog[[i]][[1L]]
      g$backlog[[i]][[1L]] <- NULL
      .member_send(g, i, b)
    }
  }
  invisible(NULL)
}

# Give a group's queued tasks to daemons with room, the least loaded first. A
# task on a daemon that has died never runs: .assert_pools_alive() fails the
# wait on it within a second.
.group_launch <- function(g) {
  while (length(g$queue)) {
    free <- which(g$load < g$depth)
    if (!length(free)) {
      break
    }
    i <- free[[which.min(g$load[free])]]
    h <- g$queue[[1L]]
    g$queue[[1L]] <- NULL
    .member_put(g, i, h, routed = TRUE)
  }
  invisible(g)
}

# Does record `g` hold tasks on the host, in its group's queue or a daemon's
# backlog?
.pool_held <- function(g) {
  length(g$queue) > 0L || any(lengths(g$backlog) > 0L)
}

# Land what has finished on the daemons of record `g` that tasks wait for,
# then give the group's queue to daemons with room.
.pool_pump <- function(g) {
  for (i in seq_along(g$members)) {
    if (length(g$queue) || length(g$backlog[[i]])) {
      for (h in g$launched[[i]]) {
        .task_poll(h)
      }
    }
  }
  .group_launch(g)
}

# Pump every record holding tasks on the host: what an idle wait does, so
# held tasks go out whichever handle the host waits on.
.groups_pump <- function() {
  for (p in ls(.garry_pools)) {
    g <- get(p, envir = .garry_pools, inherits = FALSE)
    if (.pool_held(g)) {
      .pool_pump(g)
    }
  }
  invisible(NULL)
}

# Land handle `h` if its task has finished: TRUE once it is done, with its
# value or failure in h$data. Never waits.
.task_poll <- function(h) {
  if (identical(h$state, "done")) {
    return(TRUE)
  }
  if (!identical(h$state, "launched")) {
    return(FALSE)
  }
  if (isTRUE(h$rec$closed)) {
    r <- .task_lost_value("its pool was closed")
  } else {
    r <- .task_collect(h)
  }
  if (mizu::mizu_is_sentinel(r)) {
    return(FALSE)
  }
  h$data <- r
  h$state <- "done"
  h$task <- NULL
  .member_landed(h)
  TRUE
}

# Daemon side of .pool_submit(): evaluate a task's expression, resuming
# through any interrupt. `expr` is a promise, forced inside the handler.
.daemon_resumable <- function(expr) {
  withCallingHandlers(
    expr,
    interrupt = function(cnd) {
      if (!is.null(findRestart("resume"))) invokeRestart("resume")
    }
  )
}

# Collect handle `h`'s task without waiting: its value, its failure value,
# or mizu's sentinel while it runs.
.task_collect <- function(h) {
  tryCatch(
    mizu::mizu_collect(h$task, timeout = 0),
    mizu_error_worker_died = function(e) {
      .task_lost_value("its daemon exited, probably killed (out of memory?)", e)
    },
    mizu_error_cancelled = function(e) .task_lost_value("it was cancelled", e),
    mizu_error_task_lost = function(e) {
      .task_lost_value("it was lost before it ran", e)
    },
    error = function(e) {
      if (inherits(e, "mizu_error")) {
        stop(e)
      }
      .task_raised_value(e)
    }
  )
}

# Is handle `h` still unresolved? Lands it when its task has finished, and
# first pumps its record while that holds tasks on the host. A task its
# closed pool still held on the host is lost.
.task_unresolved <- function(h) {
  if (identical(h$state, "done")) {
    return(FALSE)
  }
  g <- h$rec
  if (identical(h$state, "queued") && isTRUE(g$closed)) {
    h$data <- .task_lost_value("its pool was closed")
    h$state <- "done"
    return(FALSE)
  }
  if (.pool_held(g)) {
    .pool_pump(g)
  }
  !.task_poll(h)
}

# Cancel handles `hs`. A task still on the host is dropped there, and one
# queued on its daemon is skipped; one running finishes, and its value is
# discarded. A cancelled handle lands as lost at once: mizu frees a cancelled
# task's slot when it ends, so it can never be collected. One that finished
# first lands now, as it would at its next poll.
.task_cancel <- function(hs) {
  for (h in hs) {
    g <- h$rec
    if (identical(h$state, "queued")) {
      drop <- function(q) {
        q[!vapply(q, function(x) identical(x$id, h$id), logical(1))]
      }
      if (is.null(h$member)) {
        g$queue <- drop(g$queue)
      } else {
        g$backlog[[h$member]] <- drop(g$backlog[[h$member]])
        if (h$routed) {
          g$load[[h$member]] <- g$load[[h$member]] - 1L
        }
      }
      h$data <- .task_lost_value("it was cancelled")
      h$state <- "done"
    } else if (identical(h$state, "launched") && !isTRUE(g$closed)) {
      if (mizu::mizu_cancel(h$task)) {
        h$data <- .task_lost_value("it was cancelled")
        h$state <- "done"
        h$task <- NULL
        .member_landed(h)
      } else {
        .task_poll(h)
      }
    }
  }
  invisible(NULL)
}

# Stop the pools of `profiles` and forget them: every task they hold is
# cancelled, and each daemon exits once it has finished the task it runs.
# Returns the generation directories, for the caller to wait on and remove.
# garry reads no process's command line on Windows, so there each stop waits
# for its daemon itself, up to `wait` seconds.
.pools_stop <- function(profiles, wait = 0) {
  dirs <- character(0)
  secs <- if (.Platform$OS.type == "windows") wait else 0
  for (p in profiles) {
    g <- .pool_record(p)
    if (is.null(g)) {
      next
    }
    g$closed <- TRUE
    for (m in g$members) {
      # the stop's own warning that a daemon is still mid-task: the close
      # waits for those daemons itself
      suppressWarnings(mizu::mizu_pool_stop(m, timeout = secs))
    }
    dirs <- union(dirs, g$dir)
    rm(list = p, envir = .garry_pools)
  }
  dirs
}
