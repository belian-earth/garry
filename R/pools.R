#' @include daemon.R options.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Pool management: machine probes (cores, RAM, cgroup, shm, per-pid
# anon), the width-1 compute-profile set, CPU affinity and per-plan
# shaping, and the public pool lifecycle (garry_daemons /
# garry_pool_hygiene / garry_daemons_set).
# ---------------------------------------------------------------------------

# Package-local runtime state shared across scheduler calls: daemon
# topology recorded by garry_daemons() (reader_threads = the per-reader
# CPU-affinity width, NA/NULL when uncapped), read by the placement
# pass's cost mode.
.garry_state <- new.env(parent = emptyenv())


# Physical / logical core counts. detectCores() can return NA: pools then
# size from an assumed 4 cores, which the warning says, once a session.
.garry_cores <- function() {
  phys <- parallel::detectCores(logical = FALSE)
  logi <- parallel::detectCores(logical = TRUE)
  if (is.na(logi) || logi < 1L) {
    logi <- 4L
    cli::cli_warn(
      c(
        "cannot read this machine's core count, so garry assumes {logi} cores.",
        "i" = "Pass {.arg read} and {.arg compute} to {.fn garry_daemons}, and set {.code garry.pool_affinity = \"off\"}: CPU masks wrap at the assumed count."
      ),
      class = c("garry_cores_warning", "garry_warning"),
      .frequency = "once",
      .frequency_id = "garry_cores_unknown"
    )
  }
  if (is.na(phys) || phys < 1L) {
    phys <- logi
  }
  list(physical = as.integer(phys), logical = as.integer(logi))
}

# The memory cgroup level whose limit binds this process, in MB:
# list(avail, current, limit), where avail is the tightest
# (limit - usage + inactive file cache) over the process's cgroup and
# every ancestor with a finite limit, and current/limit belong to that
# level. NULL when no level is limited. A limit file that is there and
# will not read or parse aborts (.cgroup_lines()): only a level without
# one, or one holding "max", is unlimited. /proc/meminfo reports the HOST, so inside a container, a SLURM step or
# a systemd scope it can report tens of free GB while this process is a
# breath away from its own limit -- budgeting on it would overcommit
# straight into a cgroup OOM kill. Limits often sit on an ancestor
# (SLURM's job cgroup, a systemd slice), and usage counts the page cache
# the kernel reclaims at the limit, so the leaf alone either misses the
# limit or reads near-zero headroom in any run that has read a few GB.
#
# The walk includes the hierarchy's MOUNT ROOT. A container with a
# private cgroup namespace (Docker's default on cgroup v2, so every
# AL2023 Batch worker) sees its own cgroup as "0::/", whose files sit at
# the root itself; the walk used to skip it, so garry budgeted against
# the host's RAM there. A host's own root cgroup has no limit files, so
# including it costs nothing. cgroup v1 (and hybrid hosts, where memory
# stays on v1) reads the memory controller's line and files instead; a
# v1 container sees its cgroup at the mount root under a path that does
# not exist inside it, which the root step also covers. `root` and
# `self` are injectable for tests.
.garry_cgroup_mem <- function(
  root = "/sys/fs/cgroup",
  self = "/proc/self/cgroup"
) {
  if (!file.exists(self)) {
    return(NULL)
  } # non-Linux
  ln <- .cgroup_lines(self, 50L)
  v1 <- grep("^[0-9]+:([^:]*,)?memory(,[^:]*)?:", ln, value = TRUE)[1L]
  v2 <- grep("^0::", ln, value = TRUE)[1L]
  if (!is.na(v1)) {
    rel <- sub("^[^:]*:[^:]*:", "", v1)
    base <- file.path(root, "memory")
    f <- c(
      "memory.limit_in_bytes",
      "memory.usage_in_bytes",
      "total_inactive_file",
      "total_active_file"
    )
  } else if (!is.na(v2)) {
    rel <- sub("^0::", "", v2)
    base <- root
    f <- c("memory.max", "memory.current", "inactive_file", "active_file")
  } else {
    return(NULL)
  }
  if (!nzchar(rel)) {
    return(NULL)
  }
  # NA when the level has no such file, Inf for "max"
  read1 <- function(p) {
    if (!file.exists(p)) {
      return(NA_real_)
    }
    v <- .cgroup_lines(p, 1L)
    if (identical(v, "max")) Inf else .cgroup_number(v, p)
  }
  stat1 <- function(dir, name) {
    p <- file.path(dir, "memory.stat")
    if (!file.exists(p)) {
      return(0)
    }
    key <- paste0("^", name, " ")
    v <- sub(key, "", grep(key, .cgroup_lines(p), value = TRUE))
    if (length(v)) .cgroup_number(v[[1L]], p) else 0
  }
  parts <- strsplit(sub("^/", "", rel), "/", fixed = TRUE)[[1L]]
  parts <- parts[nzchar(parts)]
  best <- NULL
  for (k in rev(seq(0L, length(parts)))) {
    dir <- if (k == 0L) {
      base
    } else {
      file.path(base, paste(parts[seq_len(k)], collapse = "/"))
    }
    mx <- read1(file.path(dir, f[[1L]]))
    cur <- read1(file.path(dir, f[[2L]]))
    # v1 writes unlimited as ~2^63
    if (is.na(mx) || is.na(cur) || mx >= 2^60) {
      next
    }
    avail <- max(0, (mx - cur + stat1(dir, f[[3L]])) / 2^20)
    if (is.null(best) || avail < best$avail) {
      best <- list(
        avail = avail,
        current = cur / 2^20,
        limit = mx / 2^20,
        active_file = stat1(dir, f[[4L]]) / 2^20
      )
    }
  }
  best
}

# A kernel-written cgroup file, whose failure leaves the memory limit
# unknown: budgeting past it risks the OOM kill the limit will deliver.
.cgroup_lines <- function(path, n = -1L) {
  tryCatch(
    suppressWarnings(readLines(path, n = n, warn = FALSE)),
    error = function(e) .cgroup_abort(path, conditionMessage(e))
  )
}

.cgroup_number <- function(v, path) {
  n <- suppressWarnings(as.numeric(v))
  if (length(n) != 1L || is.na(n)) {
    .cgroup_abort(path, .glue("it holds {paste(v, collapse = ' ')}"))
  }
  n
}

.cgroup_abort <- function(path, why) {
  cli::cli_abort(
    c(
      "cannot read {.file {path}}, so this process's memory limit is unknown.",
      "x" = "{why}",
      "i" = "Make the cgroup files readable in this container."
    ),
    class = c("garry_memory_error", "garry_error"),
    call = NULL
  )
}

# Headroom (MB) under the binding cgroup limit; NA when unlimited.
.garry_cgroup_avail_mb <- function(
  root = "/sys/fs/cgroup",
  self = "/proc/self/cgroup"
) {
  .garry_cgroup_mem(root, self)$avail %||% NA_real_
}

# macOS reclaimable memory in MB via vm_stat, NA elsewhere or on parse
# failure. Darwin keeps truly-FREE pages near zero by design (file
# cache and inactive pages fill RAM), so memuse's freeram reads ~0.1 GB
# on an idle 7 GB machine and every garry budget clamps to its floor
# (measured on CI: the whole distributed suite serialised chunk-by-
# chunk and blew the 60-minute test budget at 28 min of CPU). The
# honest figure is free + inactive + speculative + purgeable: all
# reclaimable on demand. `lines` is injectable for off-platform tests.
.garry_darwin_avail_mb <- function(lines = NULL) {
  if (is.null(lines)) {
    if (!identical(Sys.info()[["sysname"]], "Darwin")) {
      return(NA_real_)
    }
    lines <- tryCatch(
      system2("vm_stat", stdout = TRUE, stderr = FALSE),
      error = function(e) character(0)
    )
  }
  if (length(lines) < 2L) {
    return(NA_real_)
  }
  ps <- suppressWarnings(as.numeric(
    sub(".*page size of (\\d+) bytes.*", "\\1", lines[[1L]])
  ))
  if (!is.finite(ps) || ps <= 0) {
    return(NA_real_)
  }
  page_of <- function(key) {
    ln <- grep(paste0("^Pages ", key, ":"), lines, value = TRUE)
    if (!length(ln)) {
      return(0)
    }
    v <- suppressWarnings(as.numeric(gsub("[^0-9]", "", ln[[1L]])))
    if (is.finite(v)) v else 0
  }
  pages <- page_of("free") +
    page_of("inactive") +
    page_of("speculative") +
    page_of("purgeable")
  if (pages <= 0) {
    return(NA_real_)
  }
  pages * ps / 2^20
}

# Available RAM in MB, as the MINIMUM of what the machine reports free and
# what this process's cgroup still allows. memuse supplies the machine
# figure portably (Linux/Windows/BSD); on macOS the vm_stat reclaimable
# figure replaces memuse's misleading freeram (see above). The cgroup
# term is what makes the answer meaningful inside a container, systemd
# scope or SLURM step, where the machine figure can be tens of GB while
# this process is a breath from its own limit. NA when neither can be
# determined, which leaves every budget open: that warns, once a session,
# and a run still ends in the same values.
.garry_ram_avail_mb <- function() {
  host <- .garry_darwin_avail_mb()
  why <- "no reading"
  if (!is.finite(host)) {
    host <- tryCatch(
      as.numeric(memuse::Sys.meminfo()$freeram) / 2^20,
      error = function(e) {
        why <<- conditionMessage(e)
        NA_real_
      }
    )
  }
  if (length(host) != 1L || !is.finite(host)) {
    host <- NA_real_
  }
  cg <- .garry_cgroup_avail_mb()
  if (is.na(host) && is.na(cg)) {
    cli::cli_warn(
      c(
        "cannot read the available RAM, so garry runs with no memory budget.",
        "x" = "{why}",
        "i" = "Nothing limits what runs at once: use fewer daemons if this machine runs short."
      ),
      class = c("garry_memory_warning", "garry_warning"),
      .frequency = "once",
      .frequency_id = "garry_ram_unknown"
    )
    return(NA_real_)
  }
  min(host, cg, na.rm = TRUE)
}

# Free space on /dev/shm in MB, NA when absent or unreadable. The mori
# store and the fetch cache live on tmpfs, whose pages are
# unreclaimable RAM; the budget's resident-byte accounting is an
# estimate decremented at queue-drop time, so physical high-water can
# run ahead of it within a flush window. This is the ground truth the
# budget refresh clamps against.
.garry_shm_free_mb <- function() {
  if (!dir.exists("/dev/shm")) {
    return(NA_real_)
  }
  .garry_statvfs_mb("/dev/shm")[["avail"]]
}

# Total, available and used MB of the filesystem holding `path` (NA
# when unreadable), as df reports them, without forking the host R
# process for df on every memory sweep.
.garry_statvfs_mb <- function(path) {
  v <- .Call("garry_statvfs_mb", path, PACKAGE = "garry")
  stats::setNames(v, c("total", "avail", "used"))
}

# Used space on /dev/shm in MB (the task log's shm samples), NA when
# absent or unreadable.
.garry_shm_used_mb <- function() {
  if (!dir.exists("/dev/shm")) {
    return(NA_real_)
  }
  .garry_statvfs_mb("/dev/shm")[["used"]]
}

# Human-readable size from MB: MB below 1 GiB (rounding small budgets
# to "0 GiB" erased both numbers from the oversized-chunk warning).
.garry_fmt_mb <- function(mb) {
  if (!is.finite(mb)) {
    return(as.character(mb))
  }
  if (mb >= 1024) {
    paste0(round(mb / 1024, 1), " GiB")
  } else if (mb >= 10) {
    paste0(round(mb), " MB")
  } else {
    paste0(signif(mb, 2), " MB")
  }
}

# Number of connected daemons in a mirai profile (0 if it has none).
.gd_n_compute <- function(prof) {
  as.integer(mirai::status(.compute = prof)$connections)
}

# Active compute-pool profile names: the N width-1 profiles
# garry_daemons() created (design/routed-dispatch.md). Every
# compute-facing seam (creation, teardown, affinity, pids, hygiene, ABI,
# warm-up, dispatch) loops this, and it is empty with no compute pool.
.comp_profiles <- function() {
  .garry_state$comp_profiles %||% character(0)
}

# Tasks a daemon is sent at once: one running and one queued behind it,
# so it never idles between tasks.
.daemon_depth <- 2L

# Total connected compute daemons across the profile set.
.comp_n <- function() {
  sum(vapply(.comp_profiles(), .gd_n_compute, integer(1)))
}

# A run id unique on this machine: the host pid plus a per-session count.
# It names the run's store regions and fetch directory, so it must not
# come from the RNG (drawing would move the user's .Random.seed, and two
# sessions seeded alike would share regions and a fetch directory).
.garry_run_id <- function() {
  n <- (.garry_state$run_count %||% 0L) + 1L
  .garry_state$run_count <- n
  .glue("{Sys.getpid()}x{n}")
}

# Abort if any of `profiles` has no connected daemon. A width-1 profile
# whose daemon died (an OOM kill, a crash) stays registered, and a task
# sent to it never resolves: without this check the next run blocks
# forever on its first broadcast.
.assert_pools_alive <- function(profiles, call = rlang::caller_env()) {
  dead <- profiles[vapply(profiles, .gd_n_compute, integer(1)) == 0L]
  if (length(dead)) {
    cli::cli_abort(
      c(
        "{length(dead)} garry daemon pool{?s} {?has/have} no running daemon: {.val {dead}}.",
        "i" = "A daemon was probably killed (out of memory?).",
        "i" = "Call {.fn garry_daemons} to restart the pools."
      ),
      class = "garry_pool_error",
      call = call
    )
  }
  invisible(profiles)
}

# Abort if a dispatcher has stopped handing out tasks. A broadcast sends
# one task per daemon. Lose a daemon before it takes its task and that
# task stays queued: the survivors stay connected and idle, every later
# task queues behind it, and cancelling it frees nothing (mirai 2.7.2,
# 3 readers, one busy when the broadcast came). A queue with nothing
# running, and nothing finished since the check before, is that state: a
# task waits on an idle daemon for milliseconds at most. Resetting the
# profile lets every later check read it as a pool with no daemon.
# `before` is this function's value at the last check; a width-1 profile
# has no dispatcher and no queue.
.assert_pools_moving <- function(profiles, before = list(), call = rlang::caller_env()) {
  now <- lapply(
    stats::setNames(nm = profiles),
    function(p) mirai::status(.compute = p)$mirai
  )
  blocked <- function(q) {
    !is.null(q) && q[["awaiting"]] > 0L && q[["executing"]] == 0L
  }
  stuck <- Filter(
    function(p) {
      blocked(now[[p]]) &&
        blocked(before[[p]]) &&
        now[[p]][["completed"]] == before[[p]][["completed"]]
    },
    profiles
  )
  for (p in stuck) {
    mirai::daemons(0L, .compute = p)
  }
  if (length(stuck)) {
    cli::cli_abort(
      c(
        "{length(stuck)} garry daemon pool{?s} will take no more tasks: {.val {stuck}}.",
        "i" = "A daemon was probably killed (out of memory?) with a broadcast task queued for it.",
        "i" = "Call {.fn garry_daemons} to restart the pools."
      ),
      class = c("garry_pool_error", "garry_error"),
      call = call
    )
  }
  now
}

# One idle step of a wait on `profiles`: a short sleep, and once a
# second the checks that a daemon is left to wait for and that the
# queue moves. A width-1 profile has no dispatcher to hand a dead
# daemon's task back, so the task stays unresolved forever and only this
# ends the wait.
.idle_step <- function(profiles, call = rlang::caller_env()) {
  last_check <- Sys.time()
  queues <- list()
  function() {
    if (difftime(Sys.time(), last_check, units = "secs") > 1) {
      .assert_pools_alive(profiles, call = call)
      queues <<- .assert_pools_moving(profiles, queues, call = call)
      last_check <<- Sys.time()
    }
    Sys.sleep(0.002)
  }
}

# Wait for a task, but not for a daemon that has gone. A caller with its
# own failure policy takes a bare error value back; otherwise it is the
# connection, not the task, and the caller would take it for a result.
.await_task <- function(
  h,
  profiles,
  lost = c("abort", "return"),
  call = rlang::caller_env()
) {
  lost <- match.arg(lost)
  idle <- .idle_step(profiles, call)
  while (mirai::unresolved(h)) {
    idle()
  }
  if (
    identical(lost, "abort") &&
      inherits(h$data, "errorValue") &&
      !inherits(h$data, "miraiError")
  ) {
    .task_abort("task failed on daemon", h$data, call = call)
  }
  h$data
}

# What a failed task reports. A bare error value is the connection: 19
# is a reset, the daemon dying under the task. A daemon's error is its
# header alone in as.character(): cli's bullets, where garry puts GDAL's
# cause and the next step, ride as `body`.
.task_failure <- function(x) {
  if (!inherits(x, "miraiError")) {
    code <- as.integer(x)
    if (identical(code, 19L)) {
      return("its daemon exited, probably killed (out of memory?)")
    }
    return(.glue("daemon connection error {code}"))
  }
  paste(c(as.character(x), attr(x, "body", exact = TRUE)), collapse = " ")
}

# Abort on a failed task: `what` failed, with the daemon's account, classed
# `class` and whatever garry class the daemon raised, so a handler sees the
# one condition on every route.
.task_abort <- function(
  what,
  x,
  class = "garry_task_error",
  ...,
  call = rlang::caller_env()
) {
  why <- .task_failure(x)
  raised <- grep("^garry_", attr(x, "condition.class", exact = TRUE), value = TRUE)
  cli::cli_abort(
    "{what}: {why}",
    class = unique(c(class, raised, "garry_error")),
    ...,
    call = call
  )
}

# Broadcast one QUOTED expression to every daemon of `profiles`,
# shipping `...` as task args and awaiting completion. do.call defeats
# everywhere()'s NSE so one language object serves the whole loop
# (probed 2026-08-02). A task that fails aborts, classed `class` and
# saying `what` failed: a daemon that misses a broadcast keeps stale
# state. `live_only` is for work a dead daemon has no need of (hygiene,
# credentials, teardown): it skips profiles with no daemon, and a daemon
# lost under the broadcast ends that wait; otherwise both abort.
.pool_broadcast <- function(
  expr,
  profiles = .comp_profiles(),
  ...,
  live_only = FALSE,
  what = "a pool broadcast",
  class = "garry_pool_error",
  call = rlang::caller_env()
) {
  args <- c(list(expr), list(...))
  out <- list()
  if (live_only) {
    profiles <- profiles[vapply(profiles, .gd_n_compute, integer(1)) > 0L]
  } else {
    .assert_pools_alive(profiles, call = call)
  }
  lost <- function(why) {
    cli::cli_abort(
      c("{what} failed: a daemon was lost.", "x" = "{why}"),
      class = unique(c(class, "garry_pool_error", "garry_error")),
      call = call
    )
  }
  # Send to every profile, then wait. A fresh daemon's first task loads
  # garry, about a second, so a wait per profile before the next send is
  # that second per profile. The same reason as .garry_abi_check().
  sent <- lapply(profiles, function(p) {
    do.call(mirai::everywhere, c(args, list(.compute = p)))
  })
  for (i in seq_along(profiles)) {
    out <- c(out, tryCatch(
      lapply(sent[[i]], .await_task, profiles[[i]], lost = "return"),
      garry_pool_error = function(e) {
        if (!live_only) lost(conditionMessage(e))
      }
    ))
  }
  failed <- Filter(function(r) inherits(r, "miraiError"), out)
  if (length(failed)) {
    why <- .task_failure(failed[[1L]])
    cli::cli_abort(
      c("{what} failed on {length(failed)} daemon{?s}.", "x" = "{why}"),
      class = c(class, "garry_error"),
      call = call
    )
  }
  gone <- Filter(function(r) inherits(r, "errorValue"), out)
  if (length(gone) && !live_only) {
    lost(.task_failure(gone[[1L]]))
  }
  invisible(out)
}

# Close the outputs the writer daemon holds. A writer that dies under
# the close leaves its last blocks unflushed, so its loss aborts here
# (.await_task()) as a failed close does.
.writer_close <- function(call = rlang::caller_env()) {
  closed <- .pool_broadcast(
    quote(asNamespace("garry")$.daemon_write_close()),
    profiles = "garry_write",
    what = "closing the writer's outputs",
    class = "garry_write_error",
    call = call
  )
  for (r in closed) {
    if (length(r)) {
      .gdal_close_abort(names(r)[[1L]], r[[1L]], call)
    }
  }
  invisible(NULL)
}

# A failed run's end on the writer: wait out its queued writes, whose
# errors no longer matter, then close its handles so the partial output
# is closed and deletable (Windows cannot delete an open file). The run
# already has its error, so nothing here adds one.
.writer_settle <- function(tasks) {
  prof <- "garry_write"
  if (.gd_n_compute(prof) > 0L) {
    try(
      {
        lapply(tasks, function(w) .await_task(w$h, prof, lost = "return"))
        .pool_broadcast(
          quote(asNamespace("garry")$.daemon_write_close()),
          profiles = prof,
          live_only = TRUE
        )
      },
      silent = TRUE
    )
  }
  invisible(NULL)
}

# What a daemon must hold before it reads for a run. Daemons do not
# inherit host options, so read policy is resolved here and shipped. One
# list, so no route can miss an option.
.daemon_policy <- function() {
  list(
    garry.read_retry = garry_opt("read_retry"),
    garry.warp_exact = garry_opt("warp_exact"),
    .garry_open_bytes = .gdal_daemon_open_bytes() # no user option: see .gdal_quiet_remote()
  )
}

# Start a run on `profiles`: garry attached (user stage closures call
# the g_* vocabulary unqualified), the read policy set and, with `trim`,
# the previous run's arenas trimmed (a tail plan otherwise starts with
# the fleet at the predict plan's high-water).
.daemons_run_start <- function(profiles, trim = FALSE) {
  .pool_broadcast(
    quote({
      suppressMessages(library(garry))
      options(policy)
      ns <- asNamespace("garry")
      ns$.daemon_hygiene(trim = trim && ns$.daemon_gc_due())
    }),
    profiles = profiles,
    policy = .daemon_policy(),
    trim = trim,
    what = "starting the run"
  )
}

# Every daemon pid of a mirai profile: what the CPU masks and the memory
# measurements work from, so a daemon that will not answer stops the pool.
.garry_pool_pids <- function(profile) {
  unlist(.pool_broadcast(quote(Sys.getpid()), profiles = profile, what = "the pid query"))
}

# Measured ANONYMOUS resident memory (MB) summed over the daemon
# fleet, from /proc/<pid>/status RssAnon. Anon only, deliberately: the
# mori store regions are tmpfs mappings that appear in the RSS of every
# daemon that maps them (double counted fleet-wide) and are already
# clamped against physical /dev/shm free space; RssAnon is the part the
# byte-admission model prices as working sets (R heap, XLA buffers,
# compile arenas). NA off Linux, when no pid is readable, or when the
# pid set is empty. This is the scheduler's only PER-DAEMON
# measurement: the budgets are estimates corrected by aggregate free
# RAM, and every recent memory defect was an estimate diverging from
# reality with nothing attributing the divergence to the fleet.
.garry_anon_mb_of <- function(pid) {
  # a pid may have died since the pool snapshot (e.g. a torn-down
  # writer): the error is caught, and the connection warning that
  # precedes it must not leak either
  s <- tryCatch(
    suppressWarnings(readLines(.glue("/proc/{pid}/status"), warn = FALSE)),
    error = function(e) character(0)
  )
  ln <- grep("^RssAnon:", s, value = TRUE)
  if (length(ln) != 1L) {
    return(NA_real_)
  }
  kb <- suppressWarnings(as.numeric(
    strsplit(trimws(sub("^RssAnon:", "", ln)), "\\s+")[[1L]][[1L]]
  ))
  if (is.finite(kb)) kb / 1024 else NA_real_
}

.garry_fleet_anon_mb <- function(pids) {
  if (length(pids) == 0L) {
    return(NA_real_)
  }
  v <- vapply(pids, .garry_anon_mb_of, numeric(1))
  if (all(is.na(v))) NA_real_ else sum(v, na.rm = TRUE)
}

# glibc malloc thresholds: big freed buffers get mmap'd and really returned to
# the OS instead of retained in arenas (a fused chunk otherwise leaves a daemon
# resident at its peak). These are read at process start, so they MUST be in the
# environment BEFORE daemons spawn -- children inherit them at exec. Only-if-
# unset, so a value the user exported themselves wins.
.garry_env_defaults <- function() {
  defs <- c(
    MALLOC_MMAP_THRESHOLD_ = "131072",
    MALLOC_TRIM_THRESHOLD_ = "131072"
  )
  unset <- defs[!nzchar(Sys.getenv(names(defs)))]
  if (length(unset)) do.call(Sys.setenv, as.list(unset))
}

# Cap each daemon of a pool to a disjoint interleaved CPU-affinity
# mask, so an XLA client created there sizes its thread pool to k CPUs
# instead of all cores. This is a GENERAL rule, not a reader special
# case: every process that may run an XLA client: readers via fused
# kernels, compute daemons always: gets a bounded, mostly-disjoint
# slice of the machine, which is what makes pool width a free
# parameter (slots) while admission controls concurrency. XLA sizes
# its eigen pool via tsl::port::MaxParallelism() = NumSchedulableCPUs,
# which respects sched_setaffinity, and the client inits lazily on the
# first g_jit: so affinity applied at pool creation bounds every
# later client (spike A, design/benchmark-history.md 2026-07-29: uncapped 93
# threads/daemon; k=2 -> 39 on disjoint pairs; k=1 SEGFAULTS the
# client, hence the hard floor of 2; spike B: 10 narrow clients ~2x
# the throughput of 2 uncapped fat ones on matmul kernels). Linux only;
# anywhere else the pool stays uncapped and the placement pass's
# .fuse_flops_max gate keeps wide kernels off the readers. On Linux a
# mask that cannot be set warns: the pool runs, on uncapped clients.
# `pids` take DISJOINT global slices in order: routed compute pools span
# N width-1 profiles, whose pids the caller combines. Returns the cap
# (NULL when uncapped) for .garry_state.
.pool_affinity_apply <- function(pids, k = NULL) {
  if (!identical(Sys.info()[["sysname"]], "Linux")) {
    return(NULL)
  }
  if (!nzchar(Sys.which("taskset"))) {
    .affinity_warn("the {.code taskset} program is not installed")
    return(NULL)
  }
  cores <- .garry_cores()$logical
  k <- as.integer(k %||% max(2L, cores %/% max(1L, length(pids))))
  if (k >= cores) {
    return(NULL)
  } # cap would be a no-op
  # Apply EVERY mask before judging success: an early return would leave
  # the pool half re-masked while the recorded thread state kept the old
  # width.
  failed <- character(0)
  for (i in seq_along(pids)) {
    lo <- ((i - 1L) * k) %% cores
    cpus <- paste(seq(lo, lo + k - 1L) %% cores, collapse = ",")
    out <- suppressWarnings(system2(
      "taskset",
      c("-a", "-cp", cpus, pids[[i]]),
      stdout = TRUE,
      stderr = TRUE
    ))
    if (!is.null(attr(out, "status"))) {
      failed <- c(failed, paste(out, collapse = " "))
    }
  }
  if (length(failed)) {
    .affinity_warn("{.code taskset} failed on {length(failed)} of {length(pids)} daemon{?s}: {failed[[1L]]}")
    return(NULL)
  }
  k
}

.affinity_warn <- function(what, env = parent.frame()) {
  why <- cli::format_inline(what, .envir = env)
  cli::cli_warn(
    c(
      "cannot pin the pool's daemons to CPUs, so their XLA clients run uncapped.",
      "x" = "{why}",
      "i" = "Install {.code util-linux}, or set {.code garry.pool_affinity = \"off\"} to run without masks."
    ),
    class = c("garry_affinity_warning", "garry_warning")
  )
}

# Re-shape the compute pool's affinity for THIS plan. The optimal pool
# shape is workload-dependent: fleets of moderate kernels (medians,
# matmuls) want many narrow daemons (spike B: 10 x 2-CPU ~2x two fat
# ones), while scan stages want few fat ones: each scan chunk is one
# long sequential-in-t kernel whose XLA program parallelises across
# the y/x plane, and a 2-CPU mask just makes both its compile and its
# execution slow while the byte budget keeps most of a wide pool idle
# anyway. Affinity is only sched_setaffinity, so it is re-appliable
# per execution in milliseconds: scan-bearing plans get half-machine
# masks (alternating halves; admission keeps ~2 active), everything
# else keeps the creation-time disjoint narrow masks.
.comp_pool_shape <- function(n_comp, n_scan = 0L) {
  if (is.null(.garry_state$comp_threads)) {
    return(invisible(NULL))
  }
  cores <- .garry_cores()$logical
  pids <- .garry_state$comp_pids
  if (n_scan > 0L && length(pids) > n_scan) {
    # Mixed per-role masks (routed scan plans): the designated scan
    # profiles get half-machine masks (scans are long sequential-in-t
    # kernels whose plane parallelism narrow masks starve), the map
    # profiles keep narrow disjoint slices: the mixed topology spike
    # B's data pointed at, expressible only with daemon identity.
    k_fat <- max(2L, cores %/% 2L)
    k_narrow <- max(2L, cores %/% max(1L, length(pids)))
    .pool_affinity_apply(pids[seq_len(n_scan)], k = k_fat)
    got <- .pool_affinity_apply(pids[-seq_len(n_scan)], k = k_narrow)
    if (!is.null(got)) {
      .garry_state$comp_threads <- got
    }
    # comp_threads alone cannot describe a mixed pool: the next uniform
    # plan must re-mask the scan daemons even when its width matches
    .garry_state$comp_mixed <- TRUE
    return(invisible(NULL))
  }
  k_want <- if (n_scan > 0L) {
    max(2L, cores %/% 2L)
  } else {
    max(2L, cores %/% max(1L, n_comp))
  }
  if (
    identical(.garry_state$comp_threads, k_want) &&
      !isTRUE(.garry_state$comp_mixed)
  ) {
    return(invisible(NULL))
  }
  got <- .pool_affinity_apply(pids, k = k_want)
  if (!is.null(got)) {
    .garry_state$comp_threads <- got
    .garry_state$comp_mixed <- FALSE
  }
  invisible(NULL)
}

#' Set up split mirai daemon pools for distributed execution.
#'
#' Two pools instead of one: `read` daemons execute source/warp read
#' tasks (and any kernels the placement pass fuses onto them), while
#' `compute` daemons run the materialised XLA stages. The resource
#' model is: **pool width is slots, admission is concurrency**. Every
#' daemon is pinned to a bounded, interleaved CPU mask at creation
#' (`garry_opt("pool_affinity")`; masks within a pool are mostly disjoint,
#' while read and compute masks overlap), so an XLA client created
#' anywhere is narrow rather than all-cores; the scheduler's live-RAM byte budgets
#' decide how many tasks are actually in flight; excess daemons idle
#' lean. Called with no arguments it sizes the pools to the machine:
#' `read` = all logical cores (remote fetch is latency-bound, so a
#' wide read pool keeps the network drain full) and `compute` = a
#' third of the logical cores, capped at 8 with a floor of 2; on CUDA
#' the compute pool is 2, since concurrent clients share one card.
#' `collect(distributed = TRUE)` detects the pools automatically and
#' pre-compiles stage kernels on idle daemons at run start, scan kernels
#' on the `garry_opt("scan_profiles")` designated profiles only.
#'
#' You should not need to tune these. The cases for overriding: a
#' source API that throttles concurrent reads (smaller `read`); one
#' daemon per device on multi-GPU, or one per socket on NUMA
#' (`compute`); a memory-tight box (smaller `compute`, each daemon's
#' base XLA client is ~300 MB once warmed).
#'
#' garry runs its own parallelism through these pools, so run one garry
#' session and let it use the machine. Wrapping garry calls in forked or
#' multi-process workers, such as `parallel::mclapply()` or a parallel
#' `future` plan, is discouraged and at your own risk: GDAL, curl and XLA
#' hold state that does not survive a fork, and each worker's pools would
#' compete for the same cores, memory and `/dev/shm`.
#'
#' It also applies the sensible defaults so a workload script needs no
#' preamble: the glibc `MALLOC_*` thresholds are exported BEFORE the
#' daemons spawn (read at exec, so children inherit them), and
#' [garry_gdal_config()] runs on every read daemon. Neither touches the
#' host's own GDAL config (that would hide local sidecars for the
#' caller's reads); call [garry_gdal_config()] yourself to tune host-side
#' discovery. `MALLOC_*` is only-if-unset, and `gdal_config = FALSE`
#' skips the GDAL settings entirely, on every route. Headers registered
#' with [garry_http_auth()] are applied to the new pools.
#'
#' @param read Read-pool daemon count; `NULL` (default) uses all
#'   logical cores. `0` tears the pool down.
#' @param compute Compute-pool daemon count; `NULL` (default) uses a
#'   third of the logical cores, capped at 8 with a floor of 2 (2 on
#'   CUDA: concurrent clients share one card). The compute pool's
#'   residual workloads (scans, big fused reductions) are
#'   compile-bound: every daemon that runs a scan task pays its
#'   kernel compile, so width multiplies compiles without adding
#'   admitted concurrency. Larger pools are SAFE at any width
#'   (per-daemon affinity masks and byte admission) and pay off for
#'   fleets of independent non-fusable tasks; they are an explicit
#'   choice, not the default. `0` tears down.
#' @param read_handles Open-handle cache depth on read daemons.
#'   `NULL` (default) uses `garry_opt("read_handles")`. Depth 1 suits
#'   per-slice mosaics that are rarely revisited (every open warped
#'   mosaic pins warper and connection memory); plans revisiting a few
#'   local multi-band files across many windows want a depth covering
#'   the interleaved file count, since closing a dataset discards its
#'   GDAL block cache.
#' @param gdal_config Apply [garry_gdal_config()] on the read daemons
#'   (default `TRUE`). The host session's GDAL config is never changed;
#'   call [garry_gdal_config()] yourself for host-side discovery. Set
#'   `FALSE` to leave the daemons on GDAL's defaults too (e.g. when
#'   mixing local multi-file reads). Either way every daemon's GDAL
#'   block cache is capped at `garry_opt("gdal_cachemax_mb")`: GDAL's
#'   own default is 5% of RAM per process.
#' @return Invisibly, `list(read =, compute =)`.
#' @seealso [garry_daemons_set()], [garry_pool_hygiene()], [collect()]
#' @export
garry_daemons <- function(
  read = NULL,
  compute = NULL,
  read_handles = NULL,
  gdal_config = TRUE
) {
  if (is.null(read) || is.null(compute)) {
    cr <- .garry_cores()
    # Machine-derived defaults (the routed width/K sweep,
    # design/benchmark-history.md):
    # - compute: cores/3 capped at 8 (floor 2). Scan tasks are confined
    #   to the scan_profiles daemons, so width does not multiply scan
    #   compiles or scan memory; the sweep measured the sweet spot at 6
    #   on a 20-core box, with width beyond it flat. CUDA keeps 2:
    #   concurrent clients share one card.
    # - read: all logical cores. Remote fetch is LATENCY-bound, and
    #   width = cores keeps ODC parity. A pipeline of LOCAL raw-cube
    #   reads competing with compute for cores pins its own width.
    if (is.null(compute)) {
      compute <- if (identical(garry_opt("device"), "cuda")) {
        2L
      } else {
        max(2L, min(cr$logical %/% 3L, 8L))
      }
    }
    if (is.null(read)) read <- cr$logical
  }
  .garry_opt_check()
  count <- function(v, arg, min = 0) {
    if (!is.numeric(v) || length(v) != 1L || !is.finite(v) || v < min || v != round(v)) {
      cli::cli_abort(
        "{.arg {arg}} must be a single whole number >= {min}, not {.val {v}}.",
        call = rlang::caller_env(2)
      )
    }
    as.integer(v)
  }
  read <- count(read, "read")
  compute <- count(compute, "compute")
  read_handles <- count(read_handles %||% garry_opt("read_handles"), "read_handles", 1)
  # MALLOC_* must be exported BEFORE the daemons spawn (read at exec). The GDAL
  # config is applied on the read daemons below, NOT on the host session:
  # DISABLE_READDIR_ON_OPEN=EMPTY_DIR would hide local sidecars (overviews,
  # world files) for the caller's own reads. Call garry_gdal_config() yourself
  # to tune host-side discovery.
  .garry_env_defaults()
  .garry_state$pools_set <- FALSE
  # Under covr, daemons must not load the INSTRUMENTED garry: covr
  # bakes a trace-file finalizer into the instrumented package, and a
  # daemon hitting the (benign) XLA teardown segfault leaves a
  # truncated trace that aborts covr's merge ("error reading from
  # connection", diagnosed 2026-08-12). Dropping covr's temp library
  # from R_LIBS for the spawn makes daemons run the normally installed
  # garry: identical formals (the ABI token passes), no trace files.
  # Daemon-process execution is therefore uncounted in coverage; the
  # single-process equivalence tests exercise the same logic on the
  # host, where it IS counted.
  restore_libs <- .covr_daemon_libs()
  if (!is.null(restore_libs)) {
    on.exit(restore_libs(), add = TRUE)
  }
  mirai::daemons(read, .compute = "garry_read")
  # Compute pool: N width-1 direct-connection profiles (no dispatcher
  # processes), giving the scheduler daemon identity: exact per-profile
  # kernel warmth and scan-memory confinement
  # (design/routed-dispatch.md). Any previous generation is torn down
  # first so generations never mix.
  for (p in .comp_profiles()) {
    mirai::daemons(0L, .compute = p)
  }
  .garry_state$comp_profiles <- NULL
  if (compute > 0L) {
    profs <- .glue("garry_comp_{seq_len(compute)}")
    for (p in profs) {
      mirai::daemons(1L, dispatcher = FALSE, .compute = p)
    }
    .garry_state$comp_profiles <- profs
  }
  # ONE writer daemon rides along with the pools: streamed sink chunks
  # write there instead of on the host dispatch thread (GTiff is
  # single-writer, so one daemon serialises file access safely while
  # isolating the write-path conversion transients away from the
  # host). Lean: no anvl, no GDAL session config needed.
  mirai::daemons(
    if (read > 0L || compute > 0L) 1L else 0L,
    .compute = "garry_write"
  )
  pools <- c(
    if (read > 0L) "garry_read",
    if (compute > 0L) .comp_profiles(),
    if (read > 0L || compute > 0L) "garry_write"
  )
  # GDAL's block cache defaults to 5% of RAM PER PROCESS: ~12 GB on a
  # 240 GB worker for each compute daemon and the writer, which read and
  # write through GDAL but never ran garry_gdal_config(). Cap every pool
  # at garry.gdal_cachemax_mb (.gdal_cache_cap applies it immediately).
  # The option goes with it, first: read slabs and garry_gdal_config()
  # size from it. It is fixed for the pool's life.
  if (length(pools)) {
    .pool_broadcast(
      quote({
        options(garry.gdal_cachemax_mb = mb)
        asNamespace("garry")$.gdal_cache_cap(mb)
      }),
      profiles = pools,
      mb = as.numeric(garry_opt("gdal_cachemax_mb")),
      what = "capping the GDAL block cache"
    )
  }
  if (read > 0L) {
    # Read daemons: the handle-cache depth, and once, for the pool's life,
    # the GDAL config.
    .pool_broadcast(
      quote({
        suppressMessages(library(garry))
        asNamespace("garry")$.gdal_handle_cap(hc)
        if (cfg) {
          garry::garry_gdal_config()
        }
      }),
      profiles = "garry_read",
      hc = read_handles,
      cfg = isTRUE(gdal_config),
      what = "setting up the read pool"
    )
  }
  # Pool CPU affinity (see .pool_affinity_apply): applied at pool
  # creation, BEFORE any kernel jits an XLA client anywhere. The
  # compute pool is skipped on a CUDA device (its daemons drive the
  # GPU; pinning their host threads buys nothing and can starve H2D).
  .garry_state$abi_ok <- NULL # fresh pools: re-check the ABI token
  .garry_state$prof_warm <- NULL # fresh pools hold no compiled programs
  # Fleet pids, recorded once per pool generation: the per-daemon RSS
  # poll (refresh_mem_budgets) reads /proc/<pid>/status against them,
  # and the affinity/shaping calls mask them by global index (one pid
  # collection round trip per generation, shared by both).
  .garry_state$comp_pids <- if (compute > 0L) {
    unlist(lapply(.comp_profiles(), .garry_pool_pids))
  } else {
    integer(0)
  }
  p_read <- if (read > 0L) .garry_pool_pids("garry_read") else integer(0)
  p_write <- if (read > 0L || compute > 0L) {
    .garry_pool_pids("garry_write")
  } else {
    integer(0)
  }
  .garry_state$pool_pids <- c(p_read, .garry_state$comp_pids, p_write)
  # pid -> role, for the task log's per-daemon rss rows
  .garry_state$pid_role <- stats::setNames(
    rep(
      c("read", "comp", "write"),
      c(length(p_read), length(.garry_state$comp_pids), length(p_write))
    ),
    .garry_state$pool_pids
  )
  aff <- identical(garry_opt("pool_affinity"), "auto")
  .garry_state$reader_threads <- if (aff && read > 0L) {
    .pool_affinity_apply(p_read)
  }
  .garry_state$comp_threads <- if (
    aff && compute > 0L && !identical(garry_opt("device"), "cuda")
  ) {
    .pool_affinity_apply(.garry_state$comp_pids)
  }
  .garry_state$comp_mixed <- FALSE
  # Credentials registered with garry_http_auth() reach new pools too.
  if (length(.garry_state$http_auth) && (read > 0L || compute > 0L)) {
    .http_auth_push()
  }
  .garry_state$pools_set <- read > 0L && compute > 0L
  invisible(list(read = read, compute = compute))
}

#' Reclaim daemon memory across the pools.
#'
#' Asks every daemon in the pools to release caches and return freed
#' heap pages to the operating system (glibc `malloc_trim`). With
#' `deep = TRUE` the daemons' jit caches are also evicted, forcing
#' recompiles on next use (roughly a second per map kernel, tens of
#' seconds per scan kernel); reserve that for memory pressure. Daemons
#' already trim at run start, and during a run once 128 MB of task
#' transients have passed since their last trim; call this between
#' pipeline phases when the fleet should idle lean.
#'
#' @param deep Also evict the jit caches?
#' @return Invisibly `NULL`.
#' @seealso [garry_daemons()]
#' @export
garry_pool_hygiene <- function(deep = FALSE) {
  if (isTRUE(deep)) {
    .garry_state$prof_warm <- NULL
  }
  .pool_broadcast(
    quote(asNamespace("garry")$.daemon_hygiene(deep = d)),
    profiles = c("garry_read", .comp_profiles(), "garry_write"),
    d = deep,
    live_only = TRUE
  )
  invisible(NULL)
}

#' Are the garry daemon pools set?
#'
#' `TRUE` from [garry_daemons()] creating read and compute pools until
#' they are torn down. This is the default for the `distributed` argument
#' of [collect()], so `collect(x)` uses the pools when they are set and
#' runs single-threaded otherwise. Mirrors `mirai::daemons_set()`: it
#' says the pools were set, not that every daemon is alive, so a pool that
#' lost its daemons stays `TRUE` and the next run fails with a
#' `garry_pool_error`, rather than moving onto the process the pools
#' protect. [garry_daemons()] restarts them.
#'
#' @return A single logical.
#' @export
garry_daemons_set <- function() {
  isTRUE(.garry_state$pools_set)
}

# Coverage-safe daemon library path: when covr is active, scope R_LIBS
# (for the daemon spawn only) to exclude covr's temp install library,
# provided the real garry exists elsewhere on the path. Returns a
# restore closure, or NULL when nothing needs doing. See the call site
# in garry_daemons() for the full rationale.
.covr_daemon_libs <- function() {
  if (!identical(Sys.getenv("R_COVR"), "true")) {
    return(NULL)
  }
  # Identify covr's temp library by CONTENT, not via find.package():
  # under testthat::test_local() the host garry is pkgload-loaded from
  # the SOURCE TREE, so find.package() points there while covr's
  # instrumented install still sits first on the lib path (diagnosed
  # 2026-08-12: daemons resolved the instrumented copy and wrote the
  # corrupt traces). An instrumented install is recognisable by the
  # covr save-hook covr:::add_hooks() writes into the package load
  # script.
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
  libs <- .libPaths()
  bad <- vapply(libs, instrumented, logical(1))
  clean <- libs[!bad]
  has_garry <- vapply(
    clean,
    function(l) {
      file.exists(file.path(l, "garry", "R", "garry"))
    },
    logical(1)
  )
  if (!any(bad) || !any(has_garry)) {
    return(NULL)
  } # nothing to strip, or no clean garry to fall back to
  old <- Sys.getenv("R_LIBS", unset = NA)
  Sys.setenv(R_LIBS = paste(clean, collapse = .Platform$path.sep))
  function() {
    if (is.na(old)) Sys.unsetenv("R_LIBS") else Sys.setenv(R_LIBS = old)
  }
}
