#' @include executor.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Distributed executor over mirai daemons (Phase 7, decision D16).
#
# Tasks are keyed (stage_id, chunk_idx). Dependencies: source/warp chunk
# tasks are free; compute/reduce_partial chunk j depends on chunk j of
# each input stage (chunk tables are aligned in v1); reduce_combine and
# final assembly run on the host once their inputs land.
#
# Inter-stage store: one RDS file per (stage, chunk) in a tempdir shared
# by same-host daemons. No mid-graph halo store is needed (D11): halos
# ride inside source/warp chunk files.
#
# Scheduler: polling ready-queue with an in-flight cap (back-pressure).
# Workers jit stage closures on first use and keep them in a per-daemon
# cache, so each daemon compiles each stage's <=4 shapes once (D14).
# ---------------------------------------------------------------------------

# Per-process cache used on daemons (jitted stage closures by stage id).
.daemon_cache <- new.env(parent = emptyenv())

# Daemon-side registry pinning mori shared-memory regions. A region
# lives only while its creator holds a reference (mori unlinks on GC),
# and task locals die with the task, so every share() lands here until
# the host clears the run (see `garry.store`).
.daemon_shm <- new.env(parent = emptyenv())

#' Daemon task body: release all pinned shared-memory regions.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @return `NULL`, invisibly.
#' @keywords internal
#' @export
.daemon_shm_clear <- function() {
  rm(list = ls(.daemon_shm), envir = .daemon_shm)
  gc(FALSE)
  invisible(NULL)
}

#' Daemon task body: release named shared-memory regions.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param keys Registry keys to drop (missing keys are ignored).
#' @return `NULL`, invisibly.
#' @keywords internal
#' @export
.daemon_shm_drop <- function(keys) {
  keys <- intersect(keys, ls(.daemon_shm))
  if (length(keys) > 0L) {
    rm(list = keys, envir = .daemon_shm)
    gc(FALSE)
  }
  invisible(NULL)
}

# -- Worker-side task bodies (run on daemons) ---------------------------------

# Compute-on-read (phase 12b): apply a fused single-consumer stage
# kernel to the whole padded read window, once, on the daemon that
# read it. `fuse` is list(ck, fn, dtype, out_key): jit cache key
# (content-addressed), stage closure, upload dtype, export node key.
# Returns the kernel's single export (pad consumed: core-sized).
.apply_fuse <- function(m, fuse, store_raw = FALSE) {
  if (length(ls(.daemon_cache)) > 64L)
    rm(list = ls(.daemon_cache), envir = .daemon_cache)
  jf <- .daemon_cache[[fuse$ck]]
  if (is.null(jf)) {
    jf <- g_jit(fuse$fn)
    .daemon_cache[[fuse$ck]] <- jf
  }
  up <- if (.sv_is(m)) g_upload_raw(m, "f32", .sv_dim(m))
        else g_upload(m, fuse$dtype)
  res <- jf(list(up))
  out_dev <- res[[1L]]
  # f32 kernel outputs become raw store payloads directly off the
  # device (D19): no double materialisation on the download either.
  out <- if (store_raw && identical(.g_dtype(out_dev), "f32")) {
    g_download_raw(out_dev)
  } else {
    g_download(out_dev)
  }
  rm(res, out_dev, up)
  gc(FALSE)
  out
}

#' Daemon task body: read one source window into shared memory.
#'
#' The mori-store counterpart of `.daemon_run_source` and
#' `.daemon_run_source_split`. Coarse reads share their per-compute-
#' chunk parts as elements of one shared list: consumers extract their
#' element zero-copy. (Consumer-side RANGE subsetting of a mapped
#' matrix would materialise the whole window per input - measured as
#' multi-GB of transient daemon heap on the benchmark - so the split
#' happens producer-side here too.)
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path,band,nodata Source identity.
#' @param cg `ChunkGrid`; `core` the chunk row; `key` the node key;
#'   `reg_key` the daemon registry slot pinning the region.
#' @param parts NULL for chunk-aligned reads (the buffer is shared
#'   whole under `key`), else per-compute-chunk windows (`r0`/`c0`
#'   0-based offsets, `nr`/`nc` sizes, `elt` the element name).
#' @return The shared object (serialises as its region name).
#' @keywords internal
#' @export
.daemon_run_source_shm <- function(path, band, nodata, cg, core, key,
                                   reg_key, parts = NULL,
                                   open_options = character(0),
                                   fuse = NULL, read_raw = FALSE,
                                   store_raw = FALSE) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options,
                         out = if (read_raw) "raw_f32" else "matrix")
  if (!is.null(fuse)) {
    m <- .apply_fuse(m, fuse, store_raw)
    if ((fuse$out_pad %||% 0L) > 0L)
      m <- .exec_mask_edge(m, fuse$out_pad, core, cg@grid@dims)
  }
  val <- if (is.null(parts)) stats::setNames(list(m), key) else if (.sv_is(m)) {
    slc <- .sv_slicer(m)
    stats::setNames(
      lapply(parts, function(p) slc(p$r0, p$c0, p$nr, p$nc)),
      vapply(parts, `[[`, character(1), "elt"))
  } else {
    rank3 <- length(dim(m)) == 3L    # multi-band (band, y, x) window
    stats::setNames(
      lapply(parts, function(p) {
        if (rank3)
          m[, (p$r0 + 1L):(p$r0 + p$nr), (p$c0 + 1L):(p$c0 + p$nc),
            drop = FALSE]
        else
          m[(p$r0 + 1L):(p$r0 + p$nr), (p$c0 + 1L):(p$c0 + p$nc),
            drop = FALSE]
      }),
      vapply(parts, `[[`, character(1), "elt"))
  }
  sh <- mori::share(val)
  .daemon_shm[[reg_key]] <- sh
  sh
}

#' Daemon task body: fetch one item-asset's target-window bytes to a
#' local file.
#'
#' The fetch half of the phase 12 fetch/assemble split: a plain
#' `gdal_translate -srcwin` of the window intersecting the target
#' extent (plus a warp-kernel margin), remote COG to local tmpfs,
#' native dtype and blocks — no warp, no mosaic on the remote path.
#' On failure with `garry.read_fail = "nodata"`, writes a small
#' all-nodata placeholder covering the window so the local mosaic
#' reads a hole instead of erroring (Int16 when a nodata sentinel is
#' declared, Byte 255 otherwise — the HLS QA convention).
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param location Source path/URL.
#' @param out_file Local destination.
#' @param ext,crs Target extent and CRS defining the window.
#' @param nodata Optional sentinel for the failure placeholder.
#' @param margin Source-pixel margin around the window.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_fetch_window <- function(location, out_file, ext, crs,
                                 nodata = numeric(0), margin = 8L,
                                 target_res = NULL) {
  ok <- tryCatch(
    gdal_fetch_window(location, out_file, ext, crs, margin = margin,
                      out_res = target_res),
    error = function(e) e)
  if (!isTRUE(ok)) {
    if (!identical(garry_opt("read_fail"), "nodata"))
      cli::cli_abort("fetch failed: {location} ({conditionMessage(ok)})")
    cli::cli_warn(
      "fetch failed, writing nodata window: {location} ({conditionMessage(ok)})")
    unlink(out_file)
    gdal_nodata_window(out_file, ext, crs, nodata)
  }
  TRUE
}

#' Daemon task body: run one jitted stage closure on shared-memory
#' inputs.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param cache_key Per-run jit cache key.
#' @param fn Stage closure; `in_vals`/`in_keys`/`trims`/`dtypes`
#'   describe the inputs (`in_keys` name the element to extract from
#'   each shared value: the node key, or a part name for coarse
#'   reads); `reg_key` the daemon registry slot for the result.
#' @return The shared result (serialises as its region name).
#' @keywords internal
#' @export
.daemon_run_compute_shm <- function(cache_key, fn, in_vals, in_keys,
                                    trims, dtypes, reg_key,
                                    out_keys = NULL, device = "cpu",
                                    store_raw = FALSE, edge = NULL) {
  if (length(ls(.daemon_cache)) > 64L)
    rm(list = ls(.daemon_cache), envir = .daemon_cache)
  dev <- .exec_device(device)
  jf <- .daemon_cache[[cache_key]]
  if (is.null(jf)) {
    # The host sends fn = NULL for cache keys the pre-drain warm-up
    # broadcast to this pool (the stage closure serializes at MBs per
    # task otherwise). A miss with no fn (warm-up failed, cache
    # evicted) signals the host to resend the task WITH the closure.
    if (is.null(fn))
      stop("garry_jit_miss: stage closure not cached on this daemon")
    jf <- g_jit(fn, device = dev)
    .daemon_cache[[cache_key]] <- jf
  }
  inputs <- Map(function(v, k, tr, dt) {
    .sv_upload(v[[k]], tr, dt, dev)
  }, in_vals, in_keys, trims, dtypes)
  res <- .sv_download_exports(jf(unname(inputs)), store_raw)
  # Content-addressed cache keys share one jitted wrapper across
  # structurally identical stages; the wrapper's export NAMES belong
  # to whichever stage compiled it, so rename positionally (exports
  # are ascending in every composed closure).
  if (!is.null(out_keys)) names(res) <- out_keys
  if (!is.null(edge)) {
    for (k in names(edge$pads)) {
      res[[k]] <- .exec_mask_edge(res[[k]], edge$pads[[k]],
                                  edge$core, edge$gdims)
    }
  }
  sh <- mori::share(res)
  .daemon_shm[[reg_key]] <- sh
  # Release this chunk's device buffers and input copies now: nothing
  # triggers gc between mirai tasks, so consecutive fused chunks on
  # one daemon otherwise stack ~0.5 GB of dead buffers each (phase
  # 10b: compute daemons measured at 1.2-1.7 GB anon vs a ~300 MB
  # working set). Pair with MALLOC_MMAP_THRESHOLD_/
  # MALLOC_TRIM_THRESHOLD_ in the daemon env so freed pages actually
  # return to the OS (see benchmarks/hls-median-composite.R).
  rm(inputs, res)
  gc(FALSE)
  sh
}

#' Daemon task body: pre-compile stage closures for their modal chunk
#' shape.
#'
#' Runs on compute-pool daemons at run start (see `garry_daemons()`),
#' while the read pool owns the network drain: fills the per-daemon
#' jit cache and triggers one dummy execution per stage so the XLA
#' compile (~0.9 s/stage measured) never lands on a tail chunk.
#' Get-or-create against the same cache keys the real tasks use;
#' failures are swallowed (warm-up is an optimisation, never a
#' correctness dependency).
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param specs List of per-stage specs: `ck` cache key, `fn` stage
#'   closure, `dtypes` per-input upload dtypes, `nr`/`nc` modal input
#'   dims.
#' @return `NULL`, invisibly.
#' @keywords internal
#' @export
.daemon_warm_jit <- function(specs) {
  for (sp in specs) {
    tryCatch({
      dev <- .exec_device(sp$device %||% "cpu")
      jf <- .daemon_cache[[sp$ck]]
      if (is.null(jf)) {
        jf <- g_jit(sp$fn, device = dev)
        .daemon_cache[[sp$ck]] <- jf
      }
      obs <- sp$outers %||% rep(1L, length(sp$dtypes))
      dummy <- Map(function(dt, ob) {
        if (ob > 1L) g_upload(array(0, c(ob, sp$nr, sp$nc)), dt, device = dev)
        else g_upload(matrix(0, sp$nr, sp$nc), dt, device = dev)
      }, sp$dtypes, obs)
      invisible(g_download(jf(unname(dummy))))
      rm(dummy)
    }, error = function(e) NULL)
  }
  gc(FALSE)
  invisible(NULL)
}

# Structural kernel signature: content-addressed jit cache key. Two
# stages with the same signature trace to the same XLA program for
# the same input shapes, so daemons compile ONE kernel for e.g. 55
# per-slice mask-cleanup stages instead of 55 (measured: the
# morphology benchmark's compile storm) — and identical kernels
# persist across runs. Node ids are normalized to stage-local
# indices (inputs in stored order, then members ascending); member
# fns compare by their serialized slimmed closures, so captured free
# variables participate in the identity. The only per-stage residue
# is export NAMES (node ids baked into the composed closure), which
# the task bodies overwrite positionally via `out_keys` — exports
# are sorted ascending in every composed fn, so position is
# meaning.
.stage_kernel_sig <- function(graph, s) {
  ids <- c(s@input_nodes, s@members)
  local <- stats::setNames(seq_along(ids), as.character(ids))
  norm_fn <- function(f) serialize(.slim_fn(f), NULL)
  parts <- lapply(s@members, function(id) {
    n <- graph_get(graph, id)
    base <- list(
      cls = class(n)[[1L]],
      parents = unname(local[as.character(n@parents)]),
      dtype = n@grid@dtype,
      pdims = names(graph_get(graph, n@parents[[1L]])@grid@dims))
    if (S7::S7_inherits(n, MapNode)) base$fn <- norm_fn(n@fn)
    if (S7::S7_inherits(n, FocalNode)) {
      base$fn <- norm_fn(n@fn)
      base$radius <- n@radius
      base$boundary <- n@boundary
      base$weights <- n@weights
    }
    if (S7::S7_inherits(n, ReduceNode)) {
      base$op <- n@op
      base$over <- n@over
      base$nan_rm <- n@nan_rm
      # A custom reducer's identity lives in its fn, not `op`; omitting
      # it would alias distinct kernels in the jit cache.
      if (length(n@fn)) base$fn <- norm_fn(n@fn[[1L]])
    }
    if (S7::S7_inherits(n, ScanNode)) {
      base$over <- n@over
      base$direction <- n@direction
      base$out_dtype <- n@dtype
      base$fn <- norm_fn(n@fn[[1L]])
    }
    base
  })
  sig <- list(kind = s@kind, halo = s@halo, out_pad = s@out_pad,
              parts = parts,
              n_inputs = length(s@input_nodes),
              exports = unname(local[as.character(s@exports)]))
  # In-memory hash: the previous tempfile + tools::md5sum round-trip
  # cost a file write/read/unlink per call, and the fuse-eligibility
  # loop calls this once per single-input compute stage.
  paste0("k", rlang::hash(sig))
}

# -- Host-side scheduler -------------------------------------------------------

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

# Available RAM in MB, as the MINIMUM of what the machine reports free and
# what this process's cgroup still allows. memuse supplies the machine
# figure portably (Linux/macOS/Windows/BSD); the cgroup term is what makes
# the answer meaningful inside a container, systemd scope or SLURM step,
# where the machine figure can be tens of GB while this process is a
# breath from its own limit. NA when neither can be determined.
.garry_ram_avail_mb <- function() {
  host <- tryCatch(
    as.numeric(memuse::Sys.meminfo()$freeram) / 2^20,
    error = function(e) NA_real_)
  if (length(host) != 1L || !is.finite(host)) host <- NA_real_
  cg <- .garry_cgroup_avail_mb()
  if (is.na(cg)) host else if (is.na(host)) cg else min(host, cg)
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

#' Set up split mirai daemon pools for distributed execution.
#'
#' Two pools instead of one: `read` daemons execute source/warp read
#' tasks and never load anvl/PJRT (a reader stays at ~60 MB), while
#' `compute` daemons run the fused XLA stages. Called with no arguments,
#' it sizes the pools to the machine: `compute` = physical cores (each
#' XLA median is ~one core, so hyperthreads would only thrash) and
#' `read` = logical cores (reads are ~74% network wait, so more streams
#' saturate the link without fighting for CPU). `collect(distributed =
#' TRUE)` detects the pools automatically and pre-compiles stage kernels
#' on the compute pool at run start (`garry_opt("jit_warmup")`).
#'
#' You should not need to tune these: the fetch-ordered composite
#' pipeline bounds concurrent compute working sets by
#' `garry_opt("compute_ram_fraction")` of available RAM, so a generous
#' compute pool cannot OOM (excess daemons stay idle at base RSS, and
#' a many-band job drains in memory-bounded waves). The one case for
#' overriding is a source API that throttles concurrent reads: pass a
#' smaller `read` to stay under its limit.
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
#' @param compute Compute-pool daemon count; `NULL` (default) uses
#'   physical cores. `0` tears down.
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
  rlang::check_installed("mirai", reason = "for distributed execution.")
  if (is.null(read) || is.null(compute)) {
    cr <- .garry_cores()
    if (is.null(compute)) compute <- cr$physical
    if (is.null(read))    read    <- cr$logical
  }
  read_handles <- as.integer(read_handles %||% garry_opt("read_handles"))
  # MALLOC_* must be exported BEFORE the daemons spawn (read at exec). The GDAL
  # config is applied on the read daemons below, NOT on the host session:
  # DISABLE_READDIR_ON_OPEN=EMPTY_DIR would hide local sidecars (overviews,
  # world files) for the caller's own reads. Call garry_gdal_config() yourself
  # to tune host-side discovery.
  if (isTRUE(gdal_config)) .garry_env_defaults()
  mirai::daemons(read, .compute = "garry_read", ...)
  mirai::daemons(compute, .compute = "garry_compute", ...)
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
  invisible(list(read = read, compute = compute))
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
  .gd_n_compute("garry_read") > 0L && .gd_n_compute("garry_compute") > 0L
}

#' Execute a Plan across mirai daemons.
#'
#' Requires `mirai::daemons()` to be set by the caller. Results are
#' identical to `execute_plan()` (same plan, same kernels; the
#' equivalence is gate-tested).
#'
#' @param plan A `Plan`.
#' @param path,nodata,band_names As in `execute_plan()`.
#' @return As `execute_plan()`.
#' @export
execute_plan_mirai <- function(plan, path = NULL, nodata = NULL, band_names = NULL) {
  rlang::check_installed("mirai", reason = "for distributed execution.")
  # Distributed execution runs on the garry_daemons() split pools: read/warp
  # tasks route to the read pool — where anvl/PJRT never loads, so a reader
  # stays at ~60 MB — and compute tasks to a small pool of fat daemons,
  # confining per-chunk working sets to few processes.
  if (!garry_daemons_set())
    .garry_error(paste0(
      "no garry daemon pools are running; call garry_daemons() first"),
      "garry_scheduler_error")
  n_read <- .gd_n_compute("garry_read")
  n_comp <- .gd_n_compute("garry_compute")
  pooled <- TRUE
  read_prof <- "garry_read"
  comp_prof <- "garry_compute"
  profiles <- unique(c(read_prof, comp_prof))
  # Back-pressure. Single pool: one shared bucket (unchanged
  # behavior). Pooled: reads as before; compute launches are gated
  # by a BYTE budget (below) — per-task resident estimates against
  # ram_budget_mb x pool size — so many small chunks (per-slice mask
  # cleanup, ~10 MB each) flow at full pool width while big fused
  # medians (~350 MB each) self-limit. compute_inflight remains an
  # optional hard count cap on top.
  cap_read <- max(2L * n_read, 4L)
  cap_comp <- 2L * n_comp                    # comp-pool slot depth
  cap_comp_opt <- garry_opt("compute_inflight")  # optional hard cap
  comp_budget_mb <- garry_opt("ram_budget_mb") * n_comp
  read_budget_mb <- garry_opt("read_budget_mb")
  # Largest co-resident read SET (one window per input of the widest
  # compute stage): filled during task build; the effective read budget
  # is floored above it so a wide stage's full input set can always be
  # resident at once — a budget below one set cannot deadlock (the
  # no-read-in-flight escape hatch still trickles), but it serialises
  # every read of the set, which is a crawl, not back-pressure.
  max_set_mb <- 0

  # User stage closures call the g_* vocabulary unqualified; make sure
  # the package is attached on every daemon (idempotent, once per call).
  # Read policy is resolved host-side and shipped: daemons don't
  # inherit host options.
  for (p in profiles)
    mirai::everywhere({
      suppressMessages(library(garry))
      options(garry.read_fail = rf)
    }, rf = garry_opt("read_fail"), .compute = p)

  graph <- plan@graph
  run_id <- as.integer(stats::runif(1, 1, 1e8))
  if (!requireNamespace("mori", quietly = TRUE))
    .garry_error("the distributed scheduler requires the mori package",
                 "garry_scheduler_error")
  # Raw f32 store payloads (phase 12c, D19-D21). Resolved once here:
  # daemon processes do not inherit host options, so the flag rides in
  # every task payload.
  use_raw <- .exec_use_raw_store()
  # Inter-stage store is POSIX shared memory (mori): daemons pin every
  # region they created for this run and release them once the host is done
  # (regions outlive tasks, not the run); host-side handles die with
  # `chunk_vals`. Both pools pin regions (readers: windows; computers:
  # results).
  on.exit(for (p in profiles)
    try(mirai::everywhere(garry::.daemon_shm_clear(), .compute = p),
        silent = TRUE), add = TRUE)
  chunk_vals <- new.env(parent = emptyenv())   # task key -> shared value

  # ---- fetch/assemble split (phase 12) --------------------------------
  # GTI source stages over remote locations split into per-item-asset
  # window FETCH tasks (plain gdal_translate -srcwin to tmpfs — many
  # tiny blocking reads keep the link saturated where few big warped
  # reads idle at ~25% duty cycle) plus the ordinary read task
  # ASSEMBLING the mosaic from a location-rewritten local index at
  # local speed. Requires the index sidecar gti_index_create() writes
  # and garry's own "slice = '...'" FILTER form; anything else falls
  # back to direct remote reads.
  fetch_mode <- rlang::arg_match0(garry_opt("fetch"), c("auto", "direct", "force"),
                                  arg_nm = "garry.fetch")
  fetch_root <- NULL
  fetch_state <- new.env(parent = emptyenv())  # orig index -> local info
  fetch_n_idx <- 0L
  fetch_made <- new.env(parent = emptyenv())   # fetch task key -> TRUE
  fetch_files_of <- new.env(parent = emptyenv())  # sid -> files to unlink
  fetch_reads_left <- new.env(parent = emptyenv())  # sid -> open read tasks
  on.exit(if (!is.null(fetch_root))
    unlink(fetch_root, recursive = TRUE), add = TRUE)

  prepare_fetch <- function(rpath, roo, rnodata, grid) {
    if (fetch_mode == "direct" || !startsWith(rpath, "GTI:")) return(NULL)
    ipath <- sub("^GTI:", "", rpath)
    st <- fetch_state[[ipath]]
    if (is.null(st)) {
      meta_f <- paste0(ipath, ".meta.rds")
      if (!file.exists(meta_f)) return(NULL)
      meta <- readRDS(meta_f)
      ent <- meta$entries
      if (!all(c("slice", "location") %in% names(ent))) return(NULL)
      do_fetch <- if (fetch_mode == "force") rep(TRUE, nrow(ent))
                  else grepl("^/vsi", ent$location)
      if (!any(do_fetch)) return(NULL)
      if (is.null(fetch_root)) {
        base <- if (dir.exists("/dev/shm")) "/dev/shm" else tempdir()
        fetch_root <<- file.path(base, sprintf("garry-fetch-%d", run_id))
        dir.create(fetch_root)
      }
      fetch_n_idx <<- fetch_n_idx + 1L
      sub <- file.path(fetch_root, sprintf("i%d", fetch_n_idx))
      dir.create(sub)
      dst <- file.path(sub, sprintf("r%04d.tif", seq_len(nrow(ent))))
      lent <- ent
      lent$location <- ifelse(do_fetch, dst, ent$location)
      lpath <- file.path(sub, basename(ipath))
      gti_index_create(lent, lpath, crs = meta$crs,
                       layer = meta$layer %||% "index")
      st <- list(id = fetch_n_idx, local = paste0("GTI:", lpath),
                 src = ent$location, dst = dst, do = do_fetch,
                 slice = ent$slice)
      fetch_state[[ipath]] <- st
    }
    fl <- grep("^FILTER=", roo, value = TRUE)
    if (length(fl) != 1L) return(NULL)
    slval <- regmatches(fl, regexec("^FILTER=slice = '(.*)'$", fl))[[1]][[2]]
    if (is.na(slval)) return(NULL)
    rows <- which(st$slice == slval & st$do)
    keys <- sprintf("f%d_%d", st$id, rows)
    for (k in seq_along(rows)) {
      key <- keys[[k]]
      if (!is.null(fetch_made[[key]])) next
      fetch_made[[key]] <- TRUE
      local({
        src <- st$src[[rows[[k]]]]; dst <- st$dst[[rows[[k]]]]
        ex <- grid@extent; cr <- grid@crs; nd <- rnodata
        tr <- grid@transform[[2L]]      # target x resolution: decimate coarse fetches
        add_task(key, character(0), "read", prio = 1L,
                 launch = function(prof) {
          mirai::mirai(
            garry::.daemon_fetch_window(src, dst, ex, cr, nodata = nd,
                                        target_res = tr),
            src = src, dst = dst, ex = ex, cr = cr, nd = nd, tr = tr,
            .compute = prof)
        })
      })
    }
    list(deps = keys, local = st$local,
         files = st$dst[rows])
  }


  # Consumer index in ONE pass over the stage list. Per-stage Filter
  # scans are O(stages^2) in S7 accessor calls — tens of seconds at
  # the ~2000-stage scale of a many-band multi-export plan.
  stage_kind <- vapply(plan@stages, function(s) s@kind, character(1))
  consumers_of <- vector("list", length(plan@stages))
  for (t2 in plan@stages)
    for (i in t2@inputs)
      consumers_of[[i]] <- c(consumers_of[[i]], t2@id)
  # Node id -> producing stage id (first-wins, matching .exec_in_meta's
  # Find over creation order: a spatially-reduced root is a member of
  # both its partial and combine stages, and the PARTIAL produces it).
  node_stage <- integer(length(plan@graph@nodes))
  for (t2 in rev(plan@stages)) node_stage[t2@members] <- t2@id
  warp_only <- vapply(plan@stages, function(s) {
    cons <- consumers_of[[s@id]]
    s@kind == "source_read" && length(cons) > 0L &&
      all(stage_kind[cons] == "warp") &&
      plan@sink != s@id &&
      # A source that is itself a requested sink still needs reading
      # even when its only consumers are warps (matches execute_plan's
      # guard; without it multi-export sink retrieval finds no chunks).
      !any(plan@sinks %in% s@members)
  }, logical(1))

  # Build the task table. Combine stages are host-side, handled at
  # drain. The table is an ENVIRONMENT: named-list `[[<-` inserts do a
  # linear name match plus spine copy each call — O(n^2) over the
  # build, minutes of host time at ~2e4 tasks before anything runs.
  # `seq` records insertion order (ls() on an env is alphabetical),
  # which the launch order below uses as its tie-break.
  tasks <- new.env(parent = emptyenv())
  n_task <- 0L
  add_task <- function(key, deps, pool, launch, mb = 0, prio = 2L,
                       dev = "cpu", store_mb = 0, ck = NULL) {
    n_task <<- n_task + 1L
    tasks[[key]] <- list(deps = deps, pool = pool, launch = launch,
                         mb = mb, prio = prio, dev = dev,
                         store_mb = store_mb, seq = n_task, ck = ck,
                         state = "pending")
  }
  # For coarse-reading (split) source stages: task key per compute chunk,
  # and (mori store) each compute chunk's element name in the shared
  # parts list.
  source_deps <- new.env(parent = emptyenv())
  source_elts <- new.env(parent = emptyenv())
  # Mori store lifecycle: EVERY store region (read window or compute
  # output) is refcounted per consuming TASK and dropped the moment its
  # last consumer retires — except regions the host still needs after
  # the drain (combine partials, non-streamed sink chunks; see
  # host_keep below). Without this the store only empties at
  # end-of-run: streamed sink chunks stay pinned after they are on
  # disk and every intermediate stage's full output survives the whole
  # execution — a multi-stage tail over a 22-band cube accumulates
  # gigabytes of dead regions and OOMs where its live frontier is
  # small.
  task_ins <- new.env(parent = emptyenv())       # task -> store deps consumed
  store_users <- new.env(parent = emptyenv())    # task -> n consumers left
  task_stage_of <- new.env(parent = emptyenv())  # task -> store stage id
  stage_store_mb <- new.env(parent = emptyenv()) # read stage -> window MB

  # Compute-on-read (phase 12b, CPU only): a compute stage with ONE
  # input stage — a source read consumed by nobody else — and a
  # single export executes inside the source's read tasks: the
  # kernel runs once per read window and only its OUTPUT is stored
  # and split. The per-chunk task fleet for source-fed kernel chains
  # (mask cleanup: 330 tasks on the benchmark) disappears, with its
  # dispatch, extract, upload and store round-trips.
  fused_cid <- new.env(parent = emptyenv())   # fused compute sid -> TRUE
  fuse_of <- new.env(parent = emptyenv())     # source sid -> fuse spec
  for (C in plan@stages) {
    if (C@kind != "compute" || C@id == plan@sink) next
    if (!identical(C@device, "cpu")) next
    if (length(C@inputs) != 1L || length(C@exports) != 1L) next
    S <- plan@stages[[C@inputs[[1L]]]]
    if (S@kind != "source_read" || warp_only[[S@id]]) next
    if (length(unique(consumers_of[[S@id]])) != 1L) next
    # A coalesced multi-band source keeps its consumer on the COMPUTE
    # pool: fusing a wide kernel (e.g. a 145-band MLP reduce) into the
    # read task would move the plan's whole compute onto the lean read
    # daemons and idle the warm pool. Single-band chains (mask
    # cleanup) keep the fusion win.
    if (length(graph_get(graph, S@members[[1L]])@band) > 1L) next
    fuse_of[[.key(S@id)]] <- list(
      cid = C@id,
      ck = paste0(.stage_kernel_sig(graph, C), "@", C@device),
      fn = C@fn,
      dtype = graph_get(graph, C@input_nodes[[1L]])@grid@dtype,
      out_key = .key(C@exports[[1L]]),
      out_pad = C@out_pad)
    fused_cid[[.key(C@id)]] <- TRUE
  }

  # Jit warm-up specs, one per compute stage (pooled mode): the modal
  # (full) chunk shape, compiled on every compute daemon at run start.
  warm_specs <- list()

  # Task insertion follows the launch-order invariant: the ready-queue
  # scan below launches pending tasks in insertion order, so sibling
  # producer subtrees (e.g. per-band reads) enqueue contiguously and
  # each band's fused tail overlaps the next band's read drain.
  for (s in plan@stages[.stage_launch_order(plan)]) {
    if (s@kind == "reduce_combine") next
    if (s@kind == "source_read" && warp_only[[s@id]]) next
    if (!is.null(fused_cid[[.key(s@id)]])) next   # runs on its read
    it <- chunk_iter(s@chunks)

    if (s@kind %in% c("source_read", "warp")) {
      if (s@kind == "warp") {
        wnode <- graph_get(graph, s@members[[1L]])
        snode <- graph_get(graph, wnode@parents[[1L]])
        vrt <- gdal_warp_vrt(snode@path, snode@band, wnode@target_grid,
                             wnode@resampling, src_nodata = snode@nodata)
        rpath <- vrt; rband <- 1L; rnodata <- snode@nodata
        roo <- character(0)
      } else {
        node <- graph_get(graph, s@members[[1L]])
        rpath <- .gti_resampled_path(node@path, node@resampling)
        rband <- node@band; rnodata <- node@nodata
        roo <- node@open_options
      }
      skey <- .key(s@members[[1L]])
      fspec <- fuse_of[[.key(s@id)]]
      oid <- s@id                    # store identity: fused stage id
      if (!is.null(fspec)) {
        oid <- fspec$cid
        skey <- fspec$out_key
      }
      # Raw read gate (D21): halo-free windows whose consumers see f32
      # values — the node's own dtype for pure reads, the fused
      # kernel's input dtype for compute-on-read. Non-f32 dtypes keep
      # the matrix path (bitwise consumers, integer exactness).
      raw_in <- use_raw && s@chunks@halo == 0L &&
        identical(if (is.null(fspec)) {
          graph_get(graph, s@members[[1L]])@grid@dtype
        } else {
          fspec$dtype
        }, "f32")
      fetch_deps <- character(0)
      read_pool <- "read"
      task_mb_read <- 0
      if (s@kind == "source_read") {
        fp <- prepare_fetch(rpath, roo, rnodata, s@grid)
        if (!is.null(fp)) {
          fetch_deps <- fp$deps
          rpath <- fp$local
          fetch_files_of[[.key(s@id)]] <- fp$files
          # Fetch-backed assembles are local CPU (warp + any fused
          # kernel): route them to the compute pool, which idles
          # during the drain now that compute-on-read emptied it of
          # per-chunk mask tasks — band 1 assembles DURING band 2's
          # fetches and the read pool never stops downloading.
          read_pool <- "comp"
          task_mb_read <-
            prod(pmin(as.numeric(s@chunks@chunk_dim),
                      as.numeric(s@grid@dims[c("x", "y")]))) * 24 / 2^20
        }
      }
      # Bytes this read pins in the store from launch until its last
      # consumer retires (raw f32 payloads, R doubles otherwise). The
      # launch gate budgets against the sum of these, not the task
      # count: a read fleet costs residency, not concurrency. A
      # coalesced multi-band window pins every band plane in ONE
      # region, so the outer-dim product multiplies in.
      nb_read <- max(1, prod(as.numeric(
        s@grid@dims[!names(s@grid@dims) %in% c("x", "y")])))
      store_mb_read <-
        prod(pmin(as.numeric(s@chunks@chunk_dim),
                  as.numeric(s@grid@dims[c("x", "y")])) +
             2 * s@chunks@halo) * nb_read * (if (use_raw) 4 else 8) / 2^20
      stage_store_mb[[.key(oid)]] <- store_mb_read
      split_cg <- .exec_split_cg(plan, s, consumers_of[[s@id]])
      if (is.null(split_cg)) {
        if (length(fetch_deps))
          fetch_reads_left[[.key(s@id)]] <- nrow(it)
        if (!is.null(fspec))
          source_deps[[.key(oid)]] <-
            sprintf("s%d_c%d", s@id, seq_len(nrow(it)))
        for (j in seq_len(nrow(it))) {
          local({
            sid <- s@id; jj <- j; cg <- s@chunks; core <- it[jj, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            fs <- fspec; oid2 <- oid; rr <- raw_in; sr <- use_raw
            key <- sprintf("s%d_c%d", sid, jj)
            add_task(key, fetch_deps, read_pool, mb = task_mb_read,
                     store_mb = store_mb_read,
                     launch = function(prof) {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, open_options = oo,
                                              fuse = fs, read_raw = rr,
                                              store_raw = sr),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                oo = oo, reg = sprintf("r%d_%s", run_id, key), fs = fs,
                rr = rr, sr = sr,
                .compute = prof)
            })
            task_stage_of[[key]] <- oid2
          })
        }
      } else {
        # Coarse reads. RDS store: split into per-compute-chunk files on
        # write. Mori store: share the whole read buffer; consumers
        # slice their window zero-copy. Either way compute chunk j's
        # dependency is the READ task covering it.
        its <- chunk_iter(split_cg)
        # A fused kernel consumes the halo; its output carries the
        # fused stage's out_pad ring (D22), 0 in the common case.
        H2 <- if (is.null(fspec)) 2L * split_cg@halo
              else 2L * (fspec$out_pad %||% 0L)
        dep_of <- character(nrow(its))
        elt_of <- sprintf("%s\x1f%d", skey, seq_len(nrow(its)))
        if (length(fetch_deps))
          fetch_reads_left[[.key(s@id)]] <- nrow(it)
        for (r in seq_len(nrow(it))) {
          members <- .exec_split_members(its, it[r, ])
          dep_of[members] <- sprintf("s%d_r%d", s@id, r)
          local({
            sid <- s@id; rr2 <- r; cg <- s@chunks; core <- it[rr2, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            fs <- fspec; oid2 <- oid; rr <- raw_in; sr <- use_raw
            key <- sprintf("s%d_r%d", sid, rr2)
            # Parts carry the stage halo (see .exec_split_cg): same
            # r0/c0, slice grown by 2*halo.
            parts <- lapply(members, function(j) {
              list(r0 = its$y_off[[j]] - core$y_off,
                   c0 = its$x_off[[j]] - core$x_off,
                   nr = its$y_size[[j]] + H2, nc = its$x_size[[j]] + H2,
                   elt = elt_of[[j]])
            })
            add_task(key, fetch_deps, read_pool, mb = task_mb_read,
                     store_mb = store_mb_read,
                     launch = function(prof) {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, parts = parts,
                                              open_options = oo,
                                              fuse = fs, read_raw = rr,
                                              store_raw = sr),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core,
                k2 = k2, oo = oo, parts = parts, fs = fs,
                rr = rr, sr = sr,
                reg = sprintf("r%d_%s", run_id, key),
                .compute = prof)
            })
            task_stage_of[[key]] <- oid2
          })
        }
        source_deps[[.key(oid)]] <- dep_of
        source_elts[[.key(oid)]] <- elt_of
      }

    } else {  # compute / reduce_partial
      in_meta <- .exec_in_meta(graph, s, plan@stages, node_stage)
      max_set_mb <- max(max_set_mb, sum(vapply(in_meta, function(m)
        stage_store_mb[[.key(m$id)]] %||% 0, numeric(1))))
      sig <- paste0(.stage_kernel_sig(graph, s), "@", s@device)
      okeys <- vapply(s@exports, .key, character(1))
      cd <- s@chunks@chunk_dim
      need <- s@halo + s@out_pad
      task_mb <- .stage_bytes_per_px(graph, s@members, s@input_nodes) *
        prod(as.numeric(cd) + 2 * need) / 2^20
      # The per-px estimate is calibrated for the rds store, where
      # every input lands as a private R double. Under mori the
      # inputs are shared mappings (zero-copy extraction) and the
      # resident cost is mostly the f32 device copies — roughly
      # half. The planner's chunk sizing keeps the conservative
      # figure; this only loosens the in-flight budget.
      # Inputs are shared mori mappings (zero-copy extraction); the resident
      # cost is mostly the f32 device copies -- roughly half the per-px
      # estimate, which is calibrated for private R-double inputs.
      task_mb <- task_mb / 2
      warm_specs[[length(warm_specs) + 1L]] <- list(
        ck = sig,
        fn = s@fn,
        device = s@device,
        dtypes = vapply(in_meta, function(m) m$dtype, character(1)),
        # Outer-dim product per input: a coalesced multi-band source
        # (or a cross-stage cube intermediate) warms with the rank-3
        # shape the real chunks arrive in.
        outers = vapply(s@input_nodes, function(nid) {
          d <- .node_grid(graph_get(graph, nid))@dims
          as.integer(max(1, prod(d[!names(d) %in% c("x", "y")])))
        }, integer(1)),
        nr = min(cd[[2L]], s@grid@dims[["y"]]) + 2L * need,
        nc = min(cd[[1L]], s@grid@dims[["x"]]) + 2L * need)
      for (j in seq_len(nrow(it))) {
        local({
          sid <- s@id; jj <- j; fn <- s@fn; need <- s@halo + s@out_pad
          epads <- if (length(s@export_pads)) stats::setNames(
            as.integer(s@export_pads),
            vapply(s@exports, .key, character(1))) else integer(0)
          edge <- if (any(epads > 0L)) list(
            pads = epads[epads > 0L], core = it[jj, ],
            gdims = s@grid@dims)
          meta <- in_meta
          ck <- sig                       # content-addressed jit key
          out_keys <- okeys
          sdev <- s@device
          in_deps <- vapply(meta, function(m) {
            dep <- source_deps[[.key(m$id)]]
            if (is.null(dep)) sprintf("s%d_c%d", m$id, jj) else dep[[jj]]
          }, character(1))
          in_keys <- vapply(s@input_nodes, .key, character(1))
          # Mori store: coarse-read inputs address their part element.
          shm_keys <- vapply(seq_along(meta), function(i) {
            el <- source_elts[[.key(meta[[i]]$id)]]
            if (is.null(el)) in_keys[[i]] else el[[jj]]
          }, character(1))
          trims <- vapply(meta, function(m)
            as.integer(m$pad - need), integer(1))
          dtypes <- vapply(meta, function(m) m$dtype, character(1))
          key <- sprintf("s%d_c%d", sid, jj)
          sr <- use_raw
          add_task(key, unique(in_deps), "comp", mb = task_mb,
                   dev = sdev, ck = sig,
                   launch = function(prof, with_fn = TRUE) {
            # Handles resolve at launch time: dependencies are done, so
            # `chunk_vals` holds every input's shared object (a ~30-byte
            # name over the wire). `with_fn = FALSE` sends the jit
            # cache key alone: daemons already hold every distinct
            # stage closure from the warm-up broadcast, and re-shipping
            # it costs MBs of host serialization per task (the 145-band
            # predict closure measured 3.36 MB).
            mirai::mirai(
              garry::.daemon_run_compute_shm(ck, fn, in_vals, in_keys,
                                             trims, dtypes, reg,
                                             out_keys = ok,
                                             device = dv,
                                             store_raw = sr,
                                             edge = eg),
              ck = ck, fn = if (with_fn) fn else NULL,
              in_vals = lapply(in_deps, function(d) chunk_vals[[d]]),
              in_keys = shm_keys,
              trims = trims, dtypes = dtypes,
              reg = sprintf("r%d_%s", run_id, key),
              ok = out_keys, dv = sdev, sr = sr, eg = edge,
              .compute = prof)
          })
          # Refcount every store input this task consumes (read windows
          # AND upstream compute outputs); a region frees when its last
          # consuming task retires.
          rk <- unique(in_deps)
          task_ins[[key]] <- rk
          for (r2 in rk)
            store_users[[r2]] <- (store_users[[r2]] %||% 0L) + 1L
          task_stage_of[[key]] <- sid
        })
      }
    }
  }

  # Store bytes currently pinned by launched-but-unreleased reads.
  mb_read_resident <- 0

  # host_keep (filled after the streaming-sink setup below): store
  # stage ids whose regions the host must read AFTER the drain —
  # combine partials and any sink assembled host-side rather than
  # streamed. Everything else drops as its consumers retire.
  host_keep <- new.env(parent = emptyenv())

  # Drops are batched per harvest sweep: one .daemon_shm_drop round
  # per pool instead of one per retiring task.
  pending_drop <- character(0)
  pending_drop_mb <- 0
  queue_drop <- function(keys) {
    for (rk in keys) {
      if ((store_users[[rk]] %||% 0L) > 0L) next
      sid <- task_stage_of[[rk]]
      if (is.null(sid)) next                       # no store region (fetch)
      if (isTRUE(host_keep[[.key(sid)]])) next
      task_stage_of[[rk]] <- NULL                  # drop at most once
      mb_read_resident <<- mb_read_resident - (tasks[[rk]]$store_mb %||% 0)
      pending_drop <<- c(pending_drop, rk)
      pending_drop_mb <<- pending_drop_mb + (tasks[[rk]]$store_mb %||% 0)
    }
    invisible(NULL)
  }
  # Throttled: the host gc() that releases mori mappings costs seconds
  # on a large host heap, so drops flush on a clock, not per sweep.
  # Budget ACCOUNTING (mb_read_resident) is decremented at queue time,
  # so read launches unblock immediately; only the physical unlink
  # lags, bounded by the flush interval — and by BYTES: once the
  # queued-but-unfreed regions exceed a quarter of the read budget,
  # flush regardless of the clock, or true shm high-water exceeds the
  # budget by everything launched inside one flush window.
  last_flush <- Sys.time()
  flush_drops <- function(force = FALSE) {
    if (length(pending_drop) == 0L) return(invisible(NULL))
    if (!force &&
        pending_drop_mb < 0.25 * read_budget_mb &&
        difftime(Sys.time(), last_flush, units = "secs") < 5)
      return(invisible(NULL))
    for (p in profiles)
      try(mirai::everywhere(garry::.daemon_shm_drop(regs),
                            regs = sprintf("r%d_%s", run_id, pending_drop),
                            .compute = p),
          silent = TRUE)
    # Per-key exists() filter: ls() on the store env sorts every key
    # (~40 ms at 20k entries) once per flush.
    rm(list = pending_drop[vapply(pending_drop, exists,
                                  logical(1), envir = chunk_vals,
                                  inherits = FALSE)],
       envir = chunk_vals)
    pending_drop <<- character(0)
    pending_drop_mb <<- 0
    last_flush <<- Sys.time()
    gc(FALSE)   # host munmaps its handles; regions free once unlinked
    invisible(NULL)
  }

  # On task completion: the task's own output may already be dead (a
  # streamed sink chunk with no compute consumers), and each store
  # input it consumed loses one user.
  release_store <- function(k) {
    queue_drop(k)
    deps <- task_ins[[k]]
    if (is.null(deps) || length(deps) == 0L) return(invisible(NULL))
    for (rk in deps)
      store_users[[rk]] <- store_users[[rk]] - 1L
    queue_drop(deps)
  }

  # Pre-drain jit warm-up: compile each compute stage's modal shape on
  # every compute-pool daemon while the read pool owns the drain
  # (measured: cold 1.45 s vs warmed 0.61 s per tail chunk). Fired
  # async — a daemon runs it before any compute task queued after it;
  # the handle stays referenced until the run ends. Only in pooled
  # mode: on a shared pool the warm task would displace a read (the
  # phase 10 rejection).
  warm_handle <- NULL
  # Cache keys the warm-up broadcast to every COMPUTE daemon: tasks
  # launched onto that pool send fn = NULL (key only) — the daemon
  # already holds the jitted closure. Read-pool spill launches and
  # warm-up failures fall back through the garry_jit_miss resend.
  warmed_ck <- new.env(parent = emptyenv())
  if (pooled && isTRUE(garry_opt("jit_warmup")) && length(warm_specs)) {
    # Content-addressed keys collapse structurally identical stages
    # (e.g. per-slice mask cleanup) to ONE spec.
    warm_specs <- warm_specs[!duplicated(
      vapply(warm_specs, `[[`, character(1), "ck"))]
    warm_handle <- mirai::everywhere(garry::.daemon_warm_jit(sp),
                                     sp = warm_specs,
                                     .compute = comp_prof)
    for (sp in warm_specs) warmed_ck[[sp$ck]] <- TRUE
  }

  # Streaming sink writes (phase 11.3): with a file destination, each
  # sink chunk writes the moment it lands, so all but the last band's
  # writes hide under the drain instead of running serially after it.
  # (On error the partially written file is left behind; the
  # single-threaded executor still writes at the end.)
  sink <- plan@stages[[plan@sink]]
  wnodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
  multi <- length(plan@sinks) > 1L
  stream_write <- !is.null(path) && sink@kind != "reduce_combine" && !multi
  sink_ds <- NULL
  if (stream_write) {
    sink_skey <- .key(sink@members[[length(sink@members)]])
    sink_it <- chunk_iter(sink@chunks)
    sink_spad <- .exec_export_pad(sink, sink@members[[length(sink@members)]])
    sink_task_j <- stats::setNames(
      seq_len(nrow(sink_it)),
      sprintf("s%d_c%d", sink@id, seq_len(nrow(sink_it))))
    sink_ds <- gdal_create_output(path, sink@grid, nodata = wnodata, band_names = band_names)
    on.exit(if (!is.null(sink_ds)) try(sink_ds$close(), silent = TRUE),
            add = TRUE)
  }
  # Multi-export streaming: every non-combine sink gets its own open
  # output and writes each chunk the moment its stage task lands.
  # reduce_combine sinks (host-side combines) write after the drain.
  stream_sinks <- list()
  if (!is.null(path) && multi) {
    for (kk in seq_along(plan@sinks)) {
      nid <- plan@sinks[[kk]]
      nm <- names(plan@sinks)[[kk]]
      st <- plan@stages[[max(which(vapply(plan@stages, function(s)
        nid %in% s@members, logical(1))))]]
      if (st@kind == "reduce_combine") next
      p <- if (length(path) == 1L && dir.exists(path))
        file.path(path, paste0(nm, ".tif")) else path[[nm]]
      ngrid <- graph_get(plan@graph, nid)@grid
      it <- chunk_iter(st@chunks)
      ds <- gdal_create_output(p, ngrid, nodata = wnodata,
                               band_names = band_names)
      stream_sinks[[nm]] <- list(
        key = .key(nid), it = it, pad = .exec_export_pad(st, nid), ds = ds,
        dtype = ngrid@dtype, path = p,
        task_j = stats::setNames(seq_len(nrow(it)),
                                 sprintf("s%d_c%d", st@id, seq_len(nrow(it)))))
    }
    on.exit(for (sp in stream_sinks) try(sp$ds$close(), silent = TRUE),
            add = TRUE)
  }

  # Post-drain needs: combine closures run host-side on their partial
  # stage's chunks, and any sink NOT covered by a streaming writer is
  # assembled host-side from its stage's chunks. Those stages' regions
  # must survive consumer refcounting; everything else is dropped as
  # the frontier passes.
  for (s in plan@stages)
    if (s@kind == "reduce_combine")
      host_keep[[.key(s@inputs[[1L]])]] <- TRUE
  sink_nids <- if (length(plan@sinks) > 0L) plan@sinks
    else sink@members[[length(sink@members)]]
  for (nid in unique(sink_nids)) {
    st <- plan@stages[[max(which(vapply(plan@stages, function(s)
      nid %in% s@members, logical(1))))]]
    if (st@kind == "reduce_combine") next          # parts kept above
    streamed <- (stream_write && st@id == sink@id) ||
      (multi && !is.null(path) &&
         names(plan@sinks)[match(nid, plan@sinks)] %in% names(stream_sinks))
    if (!streamed) host_keep[[.key(st@id)]] <- TRUE
  }

  # Effective read budget: never below 1.25x the widest stage's
  # co-resident window set (see max_set_mb above).
  read_budget_mb <- max(read_budget_mb, 1.25 * max_set_mb)

  # ---- Memory admission control -------------------------------------
  # The configured budgets are CAPS, not entitlements. `ram_budget_mb x
  # pool` assumes the machine is garry's alone; when the calling session
  # already holds tens of GB (model fits, point tables, a previous
  # stage's outputs) that overcommits and the run dies mid-drain. Fit
  # both budgets inside a fraction of what is ACTUALLY available, and
  # re-read during the drain so a host that grows while we run tightens
  # the gates rather than racing it to the OOM killer.
  #
  # Floors keep progress possible: compute always admits its largest
  # single task (the in-flight gates already allow one over-budget task
  # through), and reads always admit one window. A budget below those
  # serialises rather than deadlocks.
  mem_frac <- garry_opt("exec_ram_fraction")
  comp_budget_cfg <- comp_budget_mb
  read_budget_cfg <- read_budget_mb
  task_mb_max <- 0
  for (k in ls(tasks)) {
    t2 <- tasks[[k]]
    if (identical(t2$pool, "comp")) task_mb_max <- max(task_mb_max, t2$mb %||% 0)
  }
  store_mb_max <- max(c(0, vapply(ls(stage_store_mb), function(k)
    stage_store_mb[[k]] %||% 0, numeric(1))))
  mem_last_check <- Sys.time()
  refresh_mem_budgets <- function(announce = FALSE) {
    avail <- .garry_ram_avail_mb()
    if (is.na(avail) || !is.finite(mem_frac) || mem_frac <= 0) return(invisible(NULL))
    pool <- avail * mem_frac
    # Reads are cheap to hold and expensive to redo; give them at most a
    # third of the pool, compute the rest.
    rb <- max(store_mb_max, min(read_budget_cfg, pool / 3))
    cb <- max(task_mb_max, min(comp_budget_cfg, pool - rb))
    if (announce && (cb < comp_budget_cfg || rb < read_budget_cfg))
      cli::cli_inform(paste0(
        "garry: {round(avail/1024, 1)} GiB available; capping in-flight ",
        "compute at {round(cb)} MB (configured {round(comp_budget_cfg)}) ",
        "and resident reads at {round(rb)} MB (configured ",
        "{round(read_budget_cfg)})"))
    comp_budget_mb <<- cb
    read_budget_mb <<- rb
    invisible(NULL)
  }
  refresh_mem_budgets(announce = TRUE)
  # A single task that cannot fit even the whole pool is a planning
  # problem (chunks too big), not a scheduling one: it will run, alone,
  # but say so rather than let it look like a mysterious stall or kill.
  local({
    avail <- .garry_ram_avail_mb()
    if (!is.na(avail) && task_mb_max > avail * mem_frac)
      cli::cli_warn(paste0(
        "a single compute chunk is estimated at {round(task_mb_max/1024, 1)} GiB, ",
        "above the {round(avail * mem_frac / 1024, 1)} GiB execution budget; ",
        "it will run one at a time. Lower {.code garry.chunk_target_px} or ",
        "{.code garry.ram_budget_mb} to chunk finer."))
  })

  # Scan order: priority first (stable within a priority level), then
  # WINDOW-major within a priority: tasks sharing a chunk/window
  # ordinal sort together across sibling stages. Insertion order is
  # stage-major (band 1's windows, band 2's windows, ...), so a
  # multi-input stage's per-window input set would otherwise only
  # complete after nearly the whole stage's reads launched — under the
  # read byte budget that degrades to a serial trickle. Window-major
  # makes each window's cross-band set resident and releasable as a
  # unit, and lands the same source window's per-band reads together
  # in time, so pixel-interleaved sources decompress each window ~once
  # per reader (GDAL block cache) instead of once per band.
  # Fetch tasks are prio 1, everything else 2, so the read pool
  # downloads flat-out while any fetch is pending and only then
  # takes assembles — interleaving them measured the fleet at
  # ~18 MB/s where pure fetching sustains 40-50 MB/s (a local
  # assemble idles its reader's connection for ~1 s).
  task_keys <- ls(tasks)
  ord_win <- vapply(task_keys, function(k) {
    n <- suppressWarnings(as.integer(sub("^s\\d+_[rc](\\d+)$", "\\1", k)))
    if (is.na(n)) 0L else n
  }, integer(1))
  ord_prio <- vapply(task_keys, function(k) tasks[[k]]$prio, integer(1))
  ord_seq <- vapply(task_keys, function(k) tasks[[k]]$seq, integer(1))
  task_order <- task_keys[order(ord_prio, ord_win, ord_seq)]

  # Polling ready-queue with per-pool in-flight caps; compute
  # launches additionally gated by the byte budget (always at least
  # one runs, so a single over-budget task cannot deadlock).
  # Profile spill: pools are routing labels, and static membership
  # wastes half the box in each phase (measured: 16 readers idle
  # while 6 computers grind the tail, or vice versa). Comp-tagged
  # tasks launch on the compute pool while it has slots; once ALL
  # read-tagged work is done they also take idle read-pool slots —
  # the tail runs on the whole fleet.
  inflight <- list()
  n_inflight <- c(read = 0L, comp = 0L)   # by task TAG (byte budget)
  n_slot <- c(read = 0L, comp = 0L)       # by launched PROFILE slot
  n_readwork_left <- sum(vapply(task_keys, function(k)
    tasks[[k]]$pool == "read", logical(1)))
  mb_inflight <- 0
  # Reads self-limit on RESIDENT store bytes, not in-flight count: a
  # read region lives until its last consumer retires, so a plan with
  # many independent read stages (per-year predictions in one collect)
  # would otherwise drain its entire read fleet into RAM long before
  # the first compute stage released any of it. The escape hatch is
  # "no read in flight", so a stage whose own input set exceeds the
  # budget still makes progress one read at a time rather than
  # deadlocking.
  read_ok <- function(t) {
    n_inflight[["read"]] == 0L ||
      mb_read_resident + t$store_mb <= read_budget_mb
  }
  comp_ok <- function(t) {
    if (!is.null(cap_comp_opt) &&
        n_inflight[["comp"]] >= cap_comp_opt) return(FALSE)
    n_inflight[["comp"]] == 0L ||
      mb_inflight + t$mb <= comp_budget_mb
  }
  # O(1) readiness: per-task unmet-dep counters decremented through a
  # reverse index on completion. The old `all(deps %in% done)` re-hashed
  # the done set for every pending task every sweep — O(tasks^2 x deps)
  # over the drain, which at ~10^4 tasks (a 22-year multi-band predict)
  # costs the host more than the tasks themselves.
  dep_left <- new.env(parent = emptyenv())    # task -> unmet dep count
  dependents <- new.env(parent = emptyenv())  # task -> tasks waiting on it
  for (k in task_keys) {
    d <- unique(tasks[[k]]$deps)
    dep_left[[k]] <- length(d)
    for (dk in d) dependents[[dk]] <- c(dependents[[dk]], k)
  }
  n_done <- 0L
  is_ready <- function(k) dep_left[[k]] == 0L
  remaining <- function() n_done < n_total
  progress <- isTRUE(garry_opt("progress"))
  task_log <- garry_opt("task_log")
  log_line <- if (is.null(task_log)) function(...) NULL else {
    function(event, key) cat(sprintf("%.3f,%s,%s\n", unclass(Sys.time()),
                                     event, key),
                             file = task_log, append = TRUE)
  }
  n_total <- length(tasks)
  last_report <- Sys.time()
  # Launch cursor: window-major ordering makes launches near-sequential,
  # so each sweep scans from the first still-pending task instead of the
  # whole order (O(frontier), not O(n), per sweep).
  first_pending <- 1L
  # Launch state only changes at harvest (slots, byte budgets and dep
  # counters are all freed/decremented there; a launch itself can only
  # CONSUME capacity), so a sweep that harvested nothing can never
  # launch anything the previous sweep could not: skip the scan
  # entirely on those iterations instead of walking every pending
  # task per 2 ms poll (measured 16.8 ms/sweep at 20k pending).
  scan_needed <- TRUE
  while (remaining()) {
    if (scan_needed) {
    scan_needed <- FALSE
    while (first_pending <= n_total &&
           tasks[[task_order[[first_pending]]]]$state != "pending")
      first_pending <- first_pending + 1L
    for (k in task_order[seq.int(first_pending,
                                 length.out = max(0L, n_total - first_pending + 1L))]) {
      # Single pool: one shared bucket (pre-pool behavior). Pooled:
      # reads and computes throttle independently, so a saturated
      # read queue never blocks compute launches or vice versa.
      if (!pooled && length(inflight) >= cap_read) break
      t <- tasks[[k]]
      if (t$state != "pending") next
      slot <- t$pool
      if (pooled) {
        if (t$pool == "read") {
          if (n_slot[["read"]] >= cap_read) next
          if (!read_ok(t)) next
        } else {
          if (!comp_ok(t)) next
          # Fetch-backed assembles run on the compute pool but pin
          # read-store bytes like any read; gate them by the read
          # budget too, or a fetch-heavy plan drains past it and then
          # throttles genuine reads into the serial escape hatch.
          if (t$store_mb > 0 && !read_ok(t)) next
          if (n_slot[["comp"]] < cap_comp) slot <- "comp"
          else if (n_readwork_left == 0L && identical(t$dev, "cpu") &&
                   n_slot[["read"]] < cap_read) slot <- "read"
          else next
        }
      }
      if (!is_ready(k)) next
      prof <- if (slot == "read") read_prof else comp_prof
      inflight[[k]] <- if (is.null(t$ck)) t$launch(prof) else {
        # Compute-pool launches of warmed kernels ship the cache key
        # only; spill launches onto the read pool (no warm-up there)
        # always carry the closure.
        t$launch(prof, with_fn = !(slot == "comp" &&
                                     isTRUE(warmed_ck[[t$ck]])))
      }
      tasks[[k]]$slot <- slot
      n_slot[[slot]] <- n_slot[[slot]] + 1L
      n_inflight[[t$pool]] <- n_inflight[[t$pool]] + 1L
      if (t$pool == "comp") mb_inflight <- mb_inflight + t$mb
      # Read-producing tasks pin their region from launch, not from
      # completion (fetch-backed assembles run on the compute pool but
      # pin store bytes just the same).
      mb_read_resident <- mb_read_resident + t$store_mb
      tasks[[k]]$state <- "running"
      log_line("launch", k)
    }
    }
    if (length(inflight) == 0L)
      .garry_error("scheduler deadlock: no runnable tasks",
                   "garry_scheduler_error")
    harvested <- FALSE
    for (k in names(inflight)) {
      h <- inflight[[k]]
      if (!mirai::unresolved(h)) {
        if (inherits(h$data, c("miraiError", "errorValue"))) {
          # A key-only launch found the daemon's jit cache cold
          # (warm-up failed there, or the cache was wiped): resend
          # once with the full stage closure.
          if (grepl("garry_jit_miss", as.character(h$data),
                    fixed = TRUE) && !isTRUE(tasks[[k]]$resent)) {
            tasks[[k]]$resent <- TRUE
            inflight[[k]] <- tasks[[k]]$launch(
              if (tasks[[k]]$slot == "read") read_prof else comp_prof,
              with_fn = TRUE)
            next
          }
          cli::cli_abort("task {k} failed on daemon: {as.character(h$data)}")
        }
        chunk_vals[[k]] <- h$data
        tasks[[k]]$state <- "done"
        n_done <- n_done + 1L
        for (k2 in dependents[[k]])
          dep_left[[k2]] <- dep_left[[k2]] - 1L
        inflight[[k]] <- NULL
        pool_k <- tasks[[k]]$pool
        n_inflight[[pool_k]] <- n_inflight[[pool_k]] - 1L
        n_slot[[tasks[[k]]$slot]] <- n_slot[[tasks[[k]]$slot]] - 1L
        if (pool_k == "read") n_readwork_left <- n_readwork_left - 1L
        if (pool_k == "comp") mb_inflight <- mb_inflight - tasks[[k]]$mb
        harvested <- TRUE
        log_line("done", k)
        if (stream_write && !is.na(sink_task_j[k])) {
          j <- sink_task_j[[k]]
          ch <- chunk_vals[[k]][[sink_skey]]
          .exec_check_writable(ch, nrow(sink_it))
          .exec_write_chunk(sink_ds, sink_it$x_off[j], sink_it$y_off[j],
                            ch, sink_spad, sink@grid@dtype, wnodata)
          log_line("write", k)
        }
        for (sp in stream_sinks) {
          if (is.na(sp$task_j[k])) next
          j <- sp$task_j[[k]]
          ch <- chunk_vals[[k]][[sp$key]]
          .exec_check_writable(ch, nrow(sp$it))
          .exec_write_chunk(sp$ds, sp$it$x_off[j], sp$it$y_off[j],
                            ch, sp$pad, sp$dtype, wnodata)
          log_line("write", k)
        }
        release_store(k)
        # Eager fetch-cache cleanup: a fetch-backed source stage's
        # window files unlink once its last read (assemble) task is
        # done — bounds the tmpfs cache to slices still assembling.
        if (startsWith(k, "s")) {
          sk <- sub("^s(\\d+)_.*$", "\\1", k)
          left <- fetch_reads_left[[sk]]
          if (!is.null(left)) {
            fetch_reads_left[[sk]] <- left - 1L
            if (left <= 1L) {
              unlink(fetch_files_of[[sk]])
              rm(list = sk, envir = fetch_files_of)
            }
          }
        }
      }
    }
    if (harvested) {
      flush_drops()
      scan_needed <- TRUE
      # Re-read MemAvailable on a clock: the caller's own session can
      # grow while we drain (host-side fits, assembled sinks), and the
      # gates must follow the machine rather than the configuration.
      if (difftime(Sys.time(), mem_last_check, units = "secs") >= 5) {
        refresh_mem_budgets()
        mem_last_check <- Sys.time()
      }
    }
    if (progress &&
        difftime(Sys.time(), last_report, units = "secs") > 5) {
      cat(sprintf("  garry: %d/%d tasks done, %d in flight\n",
                  n_done, n_total, length(inflight)))
      last_report <- Sys.time()
    }
    if (!harvested) Sys.sleep(0.002)
  }

  # Host-side: combines, then sink retrieval (mirrors execute_plan).
  # Sink/combine stages are never split-read sources (splits only exist
  # under a compute consumer), so chunk-keyed lookup always resolves.
  flush_drops(force = TRUE)
  log_line("drain_end", "-")
  on.exit(log_line("host_end", "-"), add = TRUE)
  read_chunk <- function(sid, j) chunk_vals[[sprintf("s%d_c%d", sid, j)]]
  out_of <- function(s) {
    it <- chunk_iter(s@chunks)
    lapply(seq_len(nrow(it)), function(j) read_chunk(s@id, j))
  }

  # Streaming write already put every sink chunk on disk as it landed.
  if (stream_write) {
    sink_ds$close()
    sink_ds <- NULL
    return(invisible(path))
  }

  combine_vals <- new.env(parent = emptyenv())
  for (s in plan@stages) {
    if (s@kind != "reduce_combine") next
    part <- plan@stages[[s@inputs[[1L]]]]
    key <- .key(s@members[[1L]])
    # Combine closures run host-side on R arrays.
    partials <- lapply(lapply(out_of(part), `[[`, key), .sv_materialise)
    combine_vals[[.key(s@id)]] <- s@fn(partials)
  }

  # Multi-export: assemble/write every requested sink from the ONE run
  # (mirrors execute_plan's multi-sink tail; raw store values
  # materialise in .exec_assemble / write via .exec_write_sink).
  if (length(plan@sinks) > 1L) {
    res <- lapply(seq_along(plan@sinks), function(kk) {
      nid <- plan@sinks[[kk]]
      nm <- names(plan@sinks)[[kk]]
      if (!is.null(path) && !is.null(stream_sinks[[nm]])) {
        sp <- stream_sinks[[nm]]
        sp$ds$close()
        stream_sinks[[nm]]$ds <<- NULL
        return(sp$path)                     # streamed as chunks landed
      }
      st <- plan@stages[[max(which(vapply(plan@stages, function(s)
        nid %in% s@members, logical(1))))]]
      skey <- .key(nid)
      chunks <- if (st@kind == "reduce_combine") {
        list(combine_vals[[.key(st@id)]][[skey]])
      } else {
        lapply(out_of(st), `[[`, skey)
      }
      it <- chunk_iter(st@chunks)
      pad <- .exec_export_pad(st, nid)
      ngrid <- graph_get(plan@graph, nid)@grid
      if (!is.null(path)) {
        p <- if (length(path) == 1L && dir.exists(path))
          file.path(path, paste0(nm, ".tif"))
        else path[[nm]]
        sk <- st
        S7::prop(sk, "grid") <- ngrid
        return(.exec_write_sink(chunks, it, sk, p, nodata, band_names,
                                sink_pad = pad))
      }
      if (nrow(it) == 1L) {
        v <- .exec_trim(.sv_materialise(chunks[[1L]]), pad)
        if (is.matrix(v) && all(dim(v) == c(1L, 1L))) v[1L, 1L] else v
      } else {
        .exec_assemble(chunks, it, ngrid, pad)
      }
    })
    names(res) <- names(plan@sinks)
    return(if (is.null(path)) res else invisible(path))
  }

  key <- .key(sink@members[[length(sink@members)]])
  chunks <- if (sink@kind == "reduce_combine") {
    list(combine_vals[[.key(sink@id)]][[key]])
  } else {
    lapply(out_of(sink), `[[`, key)
  }
  it <- chunk_iter(sink@chunks)
  sink_pad <- if (sink@kind == "reduce_combine") 0L else
    .exec_export_pad(sink, sink@members[[length(sink@members)]])

  if (!is.null(path))
    return(.exec_write_sink(chunks, it, sink, path, nodata, band_names,
                            sink_pad = sink_pad))

  if (nrow(it) == 1L) {
    v <- .exec_trim(.sv_materialise(chunks[[1L]]), sink_pad)
    if (is.matrix(v) && all(dim(v) == c(1L, 1L))) return(v[1L, 1L])
    return(v)
  }
  .exec_assemble(chunks, it, sink@grid, sink_pad)
}
