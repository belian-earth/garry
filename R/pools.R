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


# Physical / logical core counts, with safe fallbacks (detectCores can NA).
.garry_cores <- function() {
  phys <- tryCatch(parallel::detectCores(logical = FALSE), error = function(e) NA_integer_)
  logi <- tryCatch(parallel::detectCores(logical = TRUE),  error = function(e) NA_integer_)
  if (is.na(logi) || logi < 1L) logi <- 4L
  if (is.na(phys) || phys < 1L) phys <- logi
  list(physical = as.integer(phys), logical = as.integer(logi))
}

# Headroom left in this process's cgroup (v2), in MB: memory.max minus
# current usage. NA when unlimited or unreadable. /proc/meminfo reports
# the HOST, so inside a container, a SLURM/systemd scope or a memory
# cgroup it can report tens of free GB while this process is a breath
# away from its own limit -- budgeting on it would overcommit straight
# into a cgroup OOM kill.
.garry_cgroup_avail_mb <- function() {
  if (!file.exists("/proc/self/cgroup")) return(NA_real_)  # non-Linux
  ln <- tryCatch(readLines("/proc/self/cgroup", n = 5L),
                 error = function(e) character(0))
  rel <- sub("^0::", "", grep("^0::", ln, value = TRUE)[1L])
  if (is.na(rel) || !nzchar(rel)) return(NA_real_)
  base <- file.path("/sys/fs/cgroup", sub("^/", "", rel))
  f_max <- file.path(base, "memory.max")
  f_cur <- file.path(base, "memory.current")
  if (!file.exists(f_max) || !file.exists(f_cur)) return(NA_real_)
  mx <- tryCatch(readLines(f_max, n = 1L), error = function(e) "max")
  if (identical(mx, "max")) return(NA_real_)          # unlimited
  mx <- suppressWarnings(as.numeric(mx))
  cur <- suppressWarnings(as.numeric(
    tryCatch(readLines(f_cur, n = 1L), error = function(e) NA)))
  if (is.na(mx) || is.na(cur)) return(NA_real_)
  max(0, (mx - cur) / 2^20)
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
    if (!identical(Sys.info()[["sysname"]], "Darwin")) return(NA_real_)
    lines <- tryCatch(system2("vm_stat", stdout = TRUE, stderr = FALSE),
                      error = function(e) character(0))
  }
  if (length(lines) < 2L) return(NA_real_)
  ps <- suppressWarnings(as.numeric(
    sub(".*page size of (\\d+) bytes.*", "\\1", lines[[1L]])))
  if (!is.finite(ps) || ps <= 0) return(NA_real_)
  page_of <- function(key) {
    ln <- grep(paste0("^Pages ", key, ":"), lines, value = TRUE)
    if (!length(ln)) return(0)
    v <- suppressWarnings(as.numeric(gsub("[^0-9]", "", ln[[1L]])))
    if (is.finite(v)) v else 0
  }
  pages <- page_of("free") + page_of("inactive") +
    page_of("speculative") + page_of("purgeable")
  if (pages <= 0) return(NA_real_)
  pages * ps / 2^20
}

# Available RAM in MB, as the MINIMUM of what the machine reports free and
# what this process's cgroup still allows. memuse supplies the machine
# figure portably (Linux/Windows/BSD); on macOS the vm_stat reclaimable
# figure replaces memuse's misleading freeram (see above). The cgroup
# term is what makes the answer meaningful inside a container, systemd
# scope or SLURM step, where the machine figure can be tens of GB while
# this process is a breath from its own limit. NA when neither can be
# determined.
.garry_ram_avail_mb <- function() {
  host <- .garry_darwin_avail_mb()
  if (!is.finite(host)) {
    host <- tryCatch(
      as.numeric(memuse::Sys.meminfo()$freeram) / 2^20,
      error = function(e) NA_real_)
  }
  if (length(host) != 1L || !is.finite(host)) host <- NA_real_
  cg <- .garry_cgroup_avail_mb()
  if (is.na(cg)) host else if (is.na(host)) cg else min(host, cg)
}

# Free space on /dev/shm in MB, NA when absent or unreadable. The mori
# store and the fetch cache live on tmpfs, whose pages are
# unreclaimable RAM; the budget's resident-byte accounting is an
# estimate decremented at queue-drop time, so physical high-water can
# run ahead of it within a flush window. This is the ground truth the
# budget refresh clamps against.
.garry_shm_free_mb <- function() {
  if (!dir.exists("/dev/shm")) return(NA_real_)
  df <- tryCatch(system2("df", c("-kP", "/dev/shm"), stdout = TRUE,
                         stderr = FALSE),
                 error = function(e) character(0))
  if (length(df) < 2L) return(NA_real_)
  avail_kb <- suppressWarnings(as.numeric(
    strsplit(trimws(df[[2L]]), "\\s+")[[1L]][[4L]]))
  if (!is.finite(avail_kb)) return(NA_real_)
  avail_kb / 1024
}

# Human-readable size from MB: MB below 1 GiB (rounding small budgets
# to "0 GiB" erased both numbers from the oversized-chunk warning).
.garry_fmt_mb <- function(mb) {
  if (!is.finite(mb)) return(as.character(mb))
  if (mb >= 1024) paste0(round(mb / 1024, 1), " GiB")
  else if (mb >= 10) paste0(round(mb), " MB")
  else paste0(signif(mb, 2), " MB")
}

# Number of connected daemons in a mirai profile (0 if none / unknown).
.gd_n_compute <- function(prof) {
  st <- tryCatch(mirai::status(.compute = prof), error = function(e) NULL)
  if (is.null(st) || !is.numeric(st$connections)) 0L else as.integer(st$connections)
}

# Active compute-pool profile names. Routed dispatch
# (garry.routed_dispatch at pool creation; design/routed-dispatch.md)
# records the N width-1 profiles garry_daemons() created; legacy mode
# is the single anonymous pool. Every compute-facing seam (creation,
# teardown, affinity, pids, hygiene, ABI, warm-up, dispatch) loops
# this, so legacy mode runs byte-identical through the same code paths.
.comp_profiles <- function() {
  .garry_state$comp_profiles %||% "garry_compute"
}

# Total connected compute daemons across the profile set.
.comp_n <- function() {
  sum(vapply(.comp_profiles(), .gd_n_compute, integer(1)))
}

# Broadcast one QUOTED expression to every daemon of `profiles`,
# shipping `...` as task args and awaiting completion. do.call defeats
# everywhere()'s NSE so one language object serves the whole loop
# (probed 2026-08-02; a substitute()-based first attempt relied on a
# nonexistent .expr_quoted argument and was backed out). `quiet`
# tolerates down profiles (teardown-adjacent broadcasts).
.pool_broadcast <- function(expr, profiles = .comp_profiles(), ...,
                            quiet = FALSE) {
  args <- c(list(expr), list(...))
  out <- list()
  for (p in profiles) {
    h <- if (quiet)
      tryCatch(do.call(mirai::everywhere, c(args, list(.compute = p))),
               error = function(e) NULL)
    else do.call(mirai::everywhere, c(args, list(.compute = p)))
    if (!is.null(h)) out <- c(out, lapply(h, function(m) m[]))
  }
  invisible(out)
}

# Every daemon pid of a mirai profile (empty when unavailable).
.garry_pool_pids <- function(profile) {
  tryCatch(
    vapply(mirai::everywhere(Sys.getpid(), .compute = profile),
           function(m) m[], integer(1)),
    error = function(e) integer(0))
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
    suppressWarnings(readLines(sprintf("/proc/%d/status", pid),
                               warn = FALSE)),
    error = function(e) character(0))
  ln <- grep("^RssAnon:", s, value = TRUE)
  if (length(ln) != 1L) return(NA_real_)
  kb <- suppressWarnings(as.numeric(
    strsplit(trimws(sub("^RssAnon:", "", ln)), "\\s+")[[1L]][[1L]]))
  if (is.finite(kb)) kb / 1024 else NA_real_
}

.garry_fleet_anon_mb <- function(pids) {
  if (length(pids) == 0L) return(NA_real_)
  v <- vapply(pids, .garry_anon_mb_of, numeric(1))
  if (all(is.na(v))) NA_real_ else sum(v, na.rm = TRUE)
}

# glibc malloc thresholds: big freed buffers get mmap'd and really returned to
# the OS instead of retained in arenas (a fused chunk otherwise leaves a daemon
# resident at its peak). These are read at process start, so they MUST be in the
# environment BEFORE daemons spawn -- children inherit them at exec. Only-if-
# unset, so a value the user exported themselves wins.
.garry_env_defaults <- function() {
  defs <- c(MALLOC_MMAP_THRESHOLD_ = "131072", MALLOC_TRIM_THRESHOLD_ = "131072")
  unset <- defs[!nzchar(Sys.getenv(names(defs)))]
  if (length(unset)) do.call(Sys.setenv, as.list(unset))
}

# Cap each daemon of a pool to a disjoint interleaved CPU-affinity
# mask, so an XLA client created there sizes its thread pool to k CPUs
# instead of all cores. This is a GENERAL rule, not a reader special
# case: every process that may run an XLA client — readers via fused
# kernels, compute daemons always — gets a bounded, mostly-disjoint
# slice of the machine, which is what makes pool width a free
# parameter (slots) while admission controls concurrency. XLA sizes
# its eigen pool via tsl::port::MaxParallelism() = NumSchedulableCPUs,
# which respects sched_setaffinity, and the client inits lazily on the
# first g_jit — so affinity applied at pool creation bounds every
# later client (spike A, benchmarks/README.md 2026-07-29: uncapped 93
# threads/daemon; k=2 -> 39 on disjoint pairs; k=1 SEGFAULTS the
# client, hence the hard floor of 2; spike B: 10 narrow clients ~2x
# the throughput of 2 uncapped fat ones on matmul kernels). Linux +
# taskset only; anywhere else the pool stays uncapped and the
# placement pass's fuse_flops_max gate keeps wide kernels off the
# readers. Returns the cap (NULL when uncapped) for .garry_state.
.pool_affinity_apply <- function(profile, n, k = NULL, pids = NULL) {
  if (!identical(Sys.info()[["sysname"]], "Linux")) return(NULL)
  if (!nzchar(Sys.which("taskset"))) return(NULL)
  cores <- .garry_cores()$logical
  k <- as.integer(k %||% max(2L, cores %/% max(1L, as.integer(n))))
  if (k >= cores) return(NULL)                # cap would be a no-op
  # `pids` overrides the profile lookup: routed compute pools span N
  # width-1 profiles whose daemons must take DISJOINT global slices,
  # so the caller passes the combined pid vector in profile order.
  pids <- pids %||% .garry_pool_pids(profile)
  if (length(pids) == 0L) return(NULL)
  # Apply EVERY mask before judging success: returning early on one
  # failed taskset left the pool half re-masked while the recorded
  # thread state kept the old width (defect hunt L5).
  ok <- TRUE
  for (i in seq_along(pids)) {
    lo <- ((i - 1L) * k) %% cores
    cpus <- paste(seq(lo, lo + k - 1L) %% cores, collapse = ",")
    st <- suppressWarnings(
      system2("taskset", c("-a", "-cp", cpus, pids[[i]]),
              stdout = FALSE, stderr = FALSE))
    if (!identical(st, 0L)) ok <- FALSE
  }
  if (!ok) return(NULL)
  k
}

# Re-shape the compute pool's affinity for THIS plan. The optimal pool
# shape is workload-dependent: fleets of moderate kernels (medians,
# matmuls) want many narrow daemons (spike B: 10 x 2-CPU ~2x two fat
# ones), while scan stages want few fat ones — each scan chunk is one
# long sequential-in-t kernel whose XLA program parallelises across
# the y/x plane, and a 2-CPU mask just makes both its compile and its
# execution slow while the byte budget keeps most of a wide pool idle
# anyway. Affinity is only sched_setaffinity, so it is re-appliable
# per execution in milliseconds: scan-bearing plans get half-machine
# masks (alternating halves; admission keeps ~2 active), everything
# else keeps the creation-time disjoint narrow masks.
.comp_pool_shape <- function(n_comp, plan_has_scan, n_scan = 0L) {
  if (is.null(.garry_state$comp_threads)) return(invisible(NULL))
  cores <- .garry_cores()$logical
  pids <- .garry_state$comp_pids
  if (n_scan > 0L && length(pids) > n_scan) {
    # Mixed per-role masks (routed scan plans): the designated scan
    # profiles get half-machine masks (scans are long sequential-in-t
    # kernels whose plane parallelism narrow masks starve), the map
    # profiles keep narrow disjoint slices — the mixed topology spike
    # B's data pointed at, expressible only with daemon identity.
    k_fat <- max(2L, cores %/% 2L)
    k_narrow <- max(2L, cores %/% max(1L, length(pids)))
    .pool_affinity_apply(NULL, n_scan, k = k_fat,
                         pids = pids[seq_len(n_scan)])
    got <- .pool_affinity_apply(NULL, length(pids) - n_scan,
                                k = k_narrow,
                                pids = pids[-seq_len(n_scan)])
    if (!is.null(got)) .garry_state$comp_threads <- got
    return(invisible(NULL))
  }
  k_want <- if (plan_has_scan) max(2L, cores %/% 2L)
            else max(2L, cores %/% max(1L, n_comp))
  if (identical(.garry_state$comp_threads, k_want))
    return(invisible(NULL))
  got <- .pool_affinity_apply(NULL, n_comp, k = k_want,
                              pids = pids)
  if (!is.null(got)) .garry_state$comp_threads <- got
  invisible(NULL)
}

#' Set up split mirai daemon pools for distributed execution.
#'
#' Two pools instead of one: `read` daemons execute source/warp read
#' tasks (and any kernels the placement pass fuses onto them), while
#' `compute` daemons run the materialised XLA stages. The resource
#' model is: **pool width is slots, admission is concurrency**. Every
#' daemon is pinned to a disjoint slice of the machine at creation
#' (`garry_opt("pool_affinity")`), so an XLA client created anywhere is
#' narrow rather than all-cores; the scheduler's live-RAM byte budgets
#' decide how many tasks are actually in flight; excess daemons idle
#' lean. Called with no arguments it sizes the pools to the machine:
#' `read` = logical cores capped at 8 (past cores/2 readers the k=2
#' affinity floor oversubscribes the machine; 8 was measured fastest
#' at scale) and `compute` = cores/3 capped at 8, floor 2 (the routed
#' width sweep's sweet spot; CUDA keeps 2 — concurrent clients share
#' one card). `collect(distributed = TRUE)` detects the pools
#' automatically and pre-compiles stage kernels at run start
#' (`garry_opt("jit_warmup")`) — scan kernels included, targeted at
#' the `garry_opt("scan_profiles")` designated profiles only.
#'
#' You should not need to tune these. The cases for overriding: a
#' source API that throttles concurrent reads (smaller `read`); one
#' daemon per device on multi-GPU, or one per socket on NUMA
#' (`compute`); a memory-tight box (smaller `compute`, each daemon's
#' base XLA client is ~300 MB once warmed).
#'
#' It also applies the sensible defaults so a workload script needs no
#' preamble: the glibc `MALLOC_*` thresholds are exported BEFORE the
#' daemons spawn (read at exec, so children inherit them), and
#' [garry_gdal_config()] runs on every read daemon. Neither touches the
#' host's own GDAL config (that would hide local sidecars for the
#' caller's reads); call [garry_gdal_config()] yourself to tune host-side
#' discovery. `MALLOC_*` is only-if-unset, and `gdal_config = FALSE`
#' skips the GDAL settings entirely.
#'
#' @param read Read-pool daemon count; `NULL` (default) uses logical
#'   cores. `0` tears the pool down.
#' @param compute Compute-pool daemon count; `NULL` (default) uses TWO
#'   with half-machine affinity masks. After the placement pass fuses
#'   kernel fleets onto the readers, the compute pool's residual
#'   workloads (scans, big fused reductions) are compile-bound: every
#'   daemon that runs a scan task pays its multi-GB kernel compile, so
#'   width multiplies compiles without adding admitted concurrency.
#'   Larger pools are SAFE at any width (per-daemon masks, byte
#'   admission, cold-kernel slow start, scan-compile surcharge) and pay
#'   off for non-fusable fleet workloads (~2x measured for matmul
#'   fleets at 10 x 2-CPU daemons); they are an explicit choice, not
#'   the default. `0` tears down.
#' @param read_handles Open-handle cache depth on read daemons.
#'   `NULL` (default) uses `garry_opt("read_handles")`. Depth 1 suits
#'   per-slice mosaics that are rarely revisited (every open warped
#'   mosaic pins warper and connection memory; measured ~15 MB/daemon
#'   saved at no wall cost on the benchmark); plans revisiting a few
#'   local multi-band files across many windows want a depth covering
#'   the interleaved file count, since closing a dataset discards its
#'   GDAL block cache.
#' @param gdal_config Apply [garry_gdal_config()] on the host and read
#'   daemons (default `TRUE`). Set `FALSE` to leave session GDAL config
#'   untouched (e.g. when mixing local multi-file reads).
#' @param ... Passed to `mirai::daemons()` for both pools.
#' @return Invisibly, `list(read =, compute =)`.
#' @export
garry_daemons <- function(read = NULL, compute = NULL, read_handles = NULL,
                          gdal_config = TRUE, ...) {
  if (is.null(read) || is.null(compute)) {
    cr <- .garry_cores()
    # Machine-derived defaults (deep review 2026-08-02, from the
    # routed width/K sweep, benchmarks/README.md):
    # - compute: cores/3 capped at 8 (floor 2). Routed dispatch made
    #   width SAFE (scan tasks are confined to the scan_profiles
    #   designated daemons, so width no longer multiplies scan
    #   compiles or scan memory) and the sweep measured the sweet spot
    #   at 6 on a 20-core box, with width beyond it flat. CUDA keeps
    #   2: concurrent clients share one card (compute=2 already
    #   RESOURCE_EXHAUSTED a 4 GB card on the SI predict).
    # - read: all logical cores. Remote fetch is LATENCY-bound: the
    #   HLS composite regressed 23.2 -> 30.8 s (band drain 18.2 ->
    #   26.0 s) when this default was briefly cut to min(cores, 8)
    #   (benchmarks/README.md 2026-08-02) — the 8 came from the SI
    #   reader-width sweep, but that regime is LOCAL raw-cube reads
    #   competing with compute for cores; pipelines in that regime
    #   pin their own width (build_si(readers = 8)). The default
    #   serves the remote-fetch case, where width = cores restores
    #   ODC parity.
    if (is.null(compute))
      compute <- if (identical(garry_opt("device"), "cuda")) 2L
                 else max(2L, min(cr$logical %/% 3L, 8L))
    if (is.null(read)) read <- cr$logical
  }
  read_handles <- as.integer(read_handles %||% garry_opt("read_handles"))
  # MALLOC_* must be exported BEFORE the daemons spawn (read at exec). The GDAL
  # config is applied on the read daemons below, NOT on the host session:
  # DISABLE_READDIR_ON_OPEN=EMPTY_DIR would hide local sidecars (overviews,
  # world files) for the caller's own reads. Call garry_gdal_config() yourself
  # to tune host-side discovery.
  if (isTRUE(gdal_config)) .garry_env_defaults()
  mirai::daemons(read, .compute = "garry_read", ...)
  # Compute pool: N width-1 direct-connection profiles (no dispatcher
  # processes — probed 2026-08-02: everywhere() state persists,
  # width-1 queues serialise, teardown clean), giving the scheduler
  # daemon identity — exact per-profile kernel warmth and scan-memory
  # confinement (design/routed-dispatch.md; the anonymous width-N pool
  # was excised after the both-mode suite and the width sweep proved
  # routing strictly dominant). Any previous generation is torn down
  # first so generations never mix.
  for (p in c(.garry_state$comp_profiles %||% character(0),
              "garry_compute"))
    try(mirai::daemons(0L, .compute = p), silent = TRUE)
  .garry_state$comp_profiles <- NULL
  if (compute > 0L) {
    profs <- sprintf("garry_comp_%d", seq_len(compute))
    for (p in profs)
      mirai::daemons(1L, dispatcher = FALSE, .compute = p, ...)
    .garry_state$comp_profiles <- profs
  }
  # ONE writer daemon rides along with the pools: streamed sink chunks
  # write there instead of on the host dispatch thread (GTiff is
  # single-writer, so one daemon serialises file access safely while
  # isolating the write-path conversion transients away from the
  # host). Lean: no anvl, no GDAL session config needed.
  mirai::daemons(if (read > 0L || compute > 0L) 1L else 0L,
                 .compute = "garry_write", ...)
  if (read > 0L) {
    # Read daemons: set the handle-cache depth, and (once) the GDAL config so it
    # is live from pool creation (the pipeline also re-applies it per run).
    w <- mirai::everywhere({
      options(garry.handle_cache_max = hc, garry.gdal_cachemax_mb = cm)
      if (cfg) { suppressMessages(library(garry)); garry::garry_gdal_config() }
    }, hc = as.integer(read_handles),
    cm = as.numeric(garry_opt("gdal_cachemax_mb")),
    cfg = isTRUE(gdal_config),
    .compute = "garry_read")
    invisible(lapply(w, function(m) m[]))
  }
  # Pool CPU affinity (see .pool_affinity_apply): applied at pool
  # creation, BEFORE any kernel jits an XLA client anywhere. The
  # compute pool is skipped on a CUDA device (its daemons drive the
  # GPU; pinning their host threads buys nothing and can starve H2D).
  .garry_state$abi_ok <- NULL       # fresh pools: re-check the ABI token
  # Fleet pids, recorded once per pool generation: the per-daemon RSS
  # poll (refresh_mem_budgets) reads /proc/<pid>/status against them,
  # and the affinity/shaping calls mask them by global index (one pid
  # collection round trip per generation, shared by both).
  .garry_state$comp_pids <- if (compute > 0L)
    unlist(lapply(.comp_profiles(), .garry_pool_pids)) else integer(0)
  .garry_state$pool_pids <- c(
    if (read > 0L) .garry_pool_pids("garry_read"),
    .garry_state$comp_pids,
    if (read > 0L || compute > 0L) .garry_pool_pids("garry_write"))
  aff <- identical(garry_opt("pool_affinity"), "auto")
  .garry_state$reader_threads <- if (aff && read > 0L)
    .pool_affinity_apply("garry_read", read)
  .garry_state$comp_threads <- if (aff && compute > 0L &&
                                   !identical(garry_opt("device"), "cuda"))
    .pool_affinity_apply(NULL, compute, pids = .garry_state$comp_pids)
  invisible(list(read = read, compute = compute))
}

#' Reclaim daemon memory across the pools.
#'
#' Broadcasts [.daemon_hygiene()] to every pool: return freed heap
#' pages to the OS (glibc `malloc_trim`), and with `deep = TRUE` also
#' evict the daemons' jit caches (forces recompiles on next use — ~1 s
#' per map kernel, ~20 s per scan kernel; reserve for memory
#' pressure). The scheduler already trims after every compute/write
#' task and at run start; call this between pipeline phases when the
#' fleet should idle lean.
#'
#' @param deep Also evict the jit caches?
#' @return Invisibly `NULL`.
#' @export
garry_pool_hygiene <- function(deep = FALSE) {
  .pool_broadcast(quote(garry::.daemon_hygiene(deep = d)),
                  profiles = c("garry_read", .comp_profiles(),
                               "garry_write"),
                  d = deep, quiet = TRUE)
  invisible(NULL)
}

#' Are the garry daemon pools running?
#'
#' `TRUE` when both mirai pools created by [garry_daemons()] (`garry_read` and
#' `garry_compute`) have daemons. This is the default for the `distributed`
#' argument of [collect()], so `collect(x)` uses the pools when they are up and
#' runs single-threaded otherwise. Mirrors `mirai::daemons_set()`.
#'
#' @return A single logical.
#' @export
garry_daemons_set <- function() {
  .gd_n_compute("garry_read") > 0L && .comp_n() > 0L
}
