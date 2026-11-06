# Split-pool boilerplate for tests: spin up the pools, tear them down
# when the calling test exits (withr::defer). Replaces the two-line
# garry_daemons(...) / on.exit(garry_daemons(0, 0, ...)) pattern at
# ~50 sites; tests that kill, rebuild or partially tear down pools
# keep explicit calls.
local_pools <- function(read, compute, ..., gdal_config = FALSE,
                        env = parent.frame()) {
  garry_daemons(read, compute, gdal_config = gdal_config, ...)
  withr::defer(garry_daemons(0, 0, gdal_config = FALSE), envir = env)
}

# Every daemon of pool `.compute` evaluates `expr` with the named data in
# `...`; waits for all of them and returns their values. A failure aborts,
# as any garry broadcast does.
.everywhere <- function(expr, ..., .compute) {
  garry:::.pool_broadcast(
    substitute(expr),
    profiles = .compute,
    ...,
    what = "a test broadcast"
  )
}

# One daemon of pool `.compute` evaluates `expr` with the named data in
# `...`; returns its value, and raises the daemon's error when it failed.
.on_daemon <- function(expr, ..., .compute) {
  v <- garry:::.await_task(
    garry:::.pool_submit(.compute, substitute(expr), list(...)),
    .compute
  )
  if (inherits(v, "garry_task_raised")) {
    stop(v$condition)
  }
  v
}

# Tasks queued for the daemons of pool `prof` (on them or on the host), and
# daemons running one, a cancelled task included.
.pool_counts <- function(prof) {
  g <- garry:::.pool_record(prof)
  queued <- sum(vapply(
    g$members,
    function(m) mizu::mizu_pool_info(m)$tasks[["pending"]],
    integer(1)
  ))
  running <- sum(vapply(
    g$members,
    function(m) mizu::mizu_pool_dump(m)$workers$park_state == "running",
    logical(1)
  ))
  c(queued = queued + length(g$queue), running = running)
}

# Wait until no daemon of `prof` runs or queues a task.
.pool_drained <- function(prof) {
  while (sum(.pool_counts(prof)) > 0L) {
    Sys.sleep(0.02)
  }
  invisible(TRUE)
}

# Run `code` under a temporary chunk-size target (shared by the
# oracle/scan/chunk-invariance sweeps; was four inline copies).
.with_chunk_px <- function(px, code) {
  old <- options(garry.chunk_target_px = px)
  on.exit(options(old))
  force(code)
}

# An empty kernel cache for one test, restored after it.
.local_kernel_cache <- function(env = parent.frame()) {
  e <- garry:::.daemon_cache
  held <- as.list(e, all.names = TRUE)
  rm(list = ls(e, all.names = TRUE), envir = e)
  withr::defer(
    {
      rm(list = ls(e, all.names = TRUE), envir = e)
      list2env(held, envir = e)
    },
    envir = env
  )
  e
}

# The most tasks of `pool` a task log shows in flight at once: what a gate
# holding a run back leaves to see.
.max_in_flight <- function(tlog, pool = "read") {
  d <- utils::read.csv(tlog)
  keys <- d$key[d$event == "launch" & d$pool == pool]
  d <- d[d$event %in% c("launch", "done") & d$key %in% keys, ]
  max(cumsum(ifelse(d$event == "launch", 1L, -1L)))
}

# A retry's backoff is the jitter times a delay, so at zero jitter retries
# run back to back.
.local_no_backoff <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(runif = function(n, ...) numeric(n), .package = "stats", .env = env)
}
