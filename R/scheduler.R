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

#' Daemon task body: read one padded source chunk into the store.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path,band,nodata Source identity.
#' @param cg `ChunkGrid`; `core` the chunk row; `key` the node key;
#'   `out_file` the store file.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_run_source <- function(path, band, nodata, cg, core, key,
                               out_file, open_options = character(0)) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options)
  # Store files are transient same-host scratch: gzip costs hundreds of
  # ms per chunk and buys nothing.
  saveRDS(stats::setNames(list(m), key), out_file, compress = FALSE)
  TRUE
}

#' Daemon task body: read one coarse source window, split it into
#' per-compute-chunk store files.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path,band,nodata Source identity.
#' @param cg Read-granularity `ChunkGrid` (halo-free); `core` the read
#'   chunk row; `key` the node key.
#' @param parts List of per-compute-chunk windows: `r0`/`c0` 0-based
#'   offsets within the read buffer, `nr`/`nc` sizes, `file` the store
#'   file.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_run_source_split <- function(path, band, nodata, cg, core, key,
                                     parts, open_options = character(0)) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options)
  for (p in parts) {
    saveRDS(stats::setNames(list(
      m[(p$r0 + 1L):(p$r0 + p$nr), (p$c0 + 1L):(p$c0 + p$nc),
        drop = FALSE]), key), p$file, compress = FALSE)
  }
  TRUE
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
                                   open_options = character(0)) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options)
  val <- if (is.null(parts)) stats::setNames(list(m), key) else {
    stats::setNames(
      lapply(parts, function(p)
        m[(p$r0 + 1L):(p$r0 + p$nr), (p$c0 + 1L):(p$c0 + p$nc),
          drop = FALSE]),
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
                                 nodata = numeric(0), margin = 8L) {
  ok <- tryCatch(
    gdal_fetch_window(location, out_file, ext, crs, margin = margin),
    error = function(e) e)
  if (!isTRUE(ok)) {
    if (!identical(garry_opt("read_fail"), "nodata"))
      stop("fetch failed: ", location, " (", conditionMessage(ok), ")")
    warning("fetch failed, writing nodata window: ", location, " (",
            conditionMessage(ok), ")", call. = FALSE)
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
                                    out_keys = NULL, device = "cpu") {
  if (length(ls(.daemon_cache)) > 64L)
    rm(list = ls(.daemon_cache), envir = .daemon_cache)
  dev <- .exec_device(device)
  jf <- .daemon_cache[[cache_key]]
  if (is.null(jf)) {
    jf <- g_jit(fn, device = dev)
    .daemon_cache[[cache_key]] <- jf
  }
  inputs <- Map(function(v, k, tr, dt) {
    g_upload(.exec_trim(v[[k]], tr), dt, device = dev)
  }, in_vals, in_keys, trims, dtypes)
  res <- g_download(jf(unname(inputs)))
  # Content-addressed cache keys share one jitted wrapper across
  # structurally identical stages; the wrapper's export NAMES belong
  # to whichever stage compiled it, so rename positionally (exports
  # are ascending in every composed closure).
  if (!is.null(out_keys)) names(res) <- out_keys
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

#' Daemon task body: run one jitted stage closure on one chunk.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param cache_key Per-run jit cache key.
#' @param fn Stage closure; `in_files`/`in_keys`/`trims`/`dtypes`
#'   describe the inputs; `out_file` the store file.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_run_compute <- function(cache_key, fn, in_files, in_keys, trims,
                                dtypes, out_file, out_keys = NULL,
                                device = "cpu") {
  if (length(ls(.daemon_cache)) > 64L)
    rm(list = ls(.daemon_cache), envir = .daemon_cache)
  dev <- .exec_device(device)
  jf <- .daemon_cache[[cache_key]]
  if (is.null(jf)) {
    jf <- g_jit(fn, device = dev)
    .daemon_cache[[cache_key]] <- jf
  }
  inputs <- Map(function(f, k, tr, dt) {
    g_upload(.exec_trim(readRDS(f)[[k]], tr), dt, device = dev)
  }, in_files, in_keys, trims, dtypes)
  res <- g_download(jf(unname(inputs)))
  # See .daemon_run_compute_shm: shared wrappers, positional rename.
  if (!is.null(out_keys)) names(res) <- out_keys
  saveRDS(res, out_file, compress = FALSE)
  # See .daemon_run_compute_shm: free chunk buffers between tasks.
  rm(inputs, res)
  gc(FALSE)
  TRUE
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
      dummy <- lapply(sp$dtypes, function(dt)
        g_upload(matrix(0, sp$nr, sp$nc), dt, device = dev))
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
    }
    base
  })
  sig <- list(kind = s@kind, halo = s@halo, parts = parts,
              n_inputs = length(s@input_nodes),
              exports = unname(local[as.character(s@exports)]))
  tf <- tempfile("garry-sig-")
  on.exit(unlink(tf), add = TRUE)
  writeBin(serialize(sig, NULL), tf)
  paste0("k", unname(tools::md5sum(tf)))
}

# -- Host-side scheduler -------------------------------------------------------

#' Set up split mirai daemon pools for distributed execution.
#'
#' Two pools instead of one: `read` daemons execute source/warp read
#' tasks and never load anvl/PJRT (a reader stays at ~60 MB), while a
#' small pool of `compute` daemons runs the fused XLA stages,
#' confining the ~0.3-1 GB per-chunk working sets to few processes.
#' `collect(distributed = TRUE)` detects the pools automatically and
#' also pre-compiles stage kernels on the compute pool at run start
#' (`garry_opt("jit_warmup")`). With no pools set up, it uses
#' `mirai::daemons()`'s default pool for everything, as before.
#'
#' Size `read` for the network (enough concurrent streams to saturate
#' the link; 12 measured right for the benchmark link) and `compute`
#' for RAM (each concurrently executing chunk holds its working set;
#' idle daemons cost base RSS only, so over-allocating `compute` for
#' the post-drain tail is cheap — the scheduler throttles compute
#' in-flight to `garry_opt("compute_inflight")` while reads are
#' draining and opens the full pool afterwards).
#'
#' MALLOC thresholds and other env vars must be exported BEFORE this
#' call: daemon processes read them at exec.
#'
#' @param read Number of read-pool daemons (0 tears the pool down).
#' @param compute Number of compute-pool daemons (0 tears down).
#' @param read_handles Open-handle cache depth on read daemons.
#'   Readers open per-slice mosaics that are rarely revisited, and
#'   every open warped mosaic pins warper and connection memory, so
#'   the default keeps only the most recent handle (measured ~15
#'   MB/daemon saved at no wall cost on the benchmark).
#' @param ... Passed to `mirai::daemons()` for both pools.
#' @return Invisibly, `list(read =, compute =)`.
#' @export
garry_daemons <- function(read, compute, read_handles = 1L, ...) {
  if (!requireNamespace("mirai", quietly = TRUE))
    stop("the mirai package is required for distributed execution")
  mirai::daemons(read, .compute = "garry_read", ...)
  mirai::daemons(compute, .compute = "garry_compute", ...)
  if (read > 0L) {
    w <- mirai::everywhere(options(garry.handle_cache_max = hc),
                           hc = as.integer(read_handles),
                           .compute = "garry_read")
    invisible(lapply(w, function(m) m[]))
  }
  invisible(list(read = read, compute = compute))
}

#' Execute a Plan across mirai daemons.
#'
#' Requires `mirai::daemons()` to be set by the caller. Results are
#' identical to `execute_plan()` (same plan, same kernels; the
#' equivalence is gate-tested).
#'
#' @param plan A `Plan`.
#' @param path,nodata As in `execute_plan()`.
#' @return As `execute_plan()`.
#' @export
execute_plan_mirai <- function(plan, path = NULL, nodata = NULL) {
  if (!requireNamespace("mirai", quietly = TRUE))
    stop("the mirai package is required for distributed execution")
  # Pooled mode (phase 11.1): when the garry_read/garry_compute mirai
  # compute profiles both have daemons (garry_daemons()), read/warp
  # tasks route to the read pool — where anvl/PJRT never loads, so a
  # reader stays at ~60 MB — and compute tasks to a small pool of fat
  # daemons, confining per-chunk working sets to few processes.
  # Otherwise everything runs on mirai's default profile, exactly as
  # before pools existed.
  n_of <- function(p) {
    st <- tryCatch(mirai::status(.compute = p), error = function(e) NULL)
    if (is.null(st) || !is.numeric(st$connections)) 0L
    else as.integer(st$connections)
  }
  n_read <- n_of("garry_read")
  n_comp <- n_of("garry_compute")
  pooled <- n_read > 0L && n_comp > 0L
  if (!pooled) {
    n_read <- n_comp <- n_of("default")
    if (n_read < 1L)
      .garry_error(paste0(
        "no mirai daemons: call mirai::daemons(n) or ",
        "garry_daemons(read, compute) first"), "garry_scheduler_error")
  }
  read_prof <- if (pooled) "garry_read" else "default"
  comp_prof <- if (pooled) "garry_compute" else "default"
  profiles <- unique(c(read_prof, comp_prof))
  # Back-pressure. Single pool: one shared bucket (unchanged
  # behavior). Pooled: reads as before; compute launches are gated
  # by a BYTE budget (below) — per-task resident estimates against
  # ram_budget_mb x pool size — so many small chunks (per-slice mask
  # cleanup, ~10 MB each) flow at full pool width while big fused
  # medians (~350 MB each) self-limit. compute_inflight remains an
  # optional hard count cap on top.
  cap_read <- max(2L * n_read, 4L)
  cap_comp <- garry_opt("compute_inflight") %||% (2L * n_comp)
  comp_budget_mb <- garry_opt("ram_budget_mb") * n_comp

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
  store_mode <- match.arg(garry_opt("store"), c("rds", "mori"))
  use_shm <- store_mode == "mori"
  if (use_shm && !requireNamespace("mori", quietly = TRUE))
    .garry_error("options(garry.store = \"mori\") needs the mori package",
                 "garry_scheduler_error")
  store <- file.path(tempdir(), paste0("garry-store-", run_id))
  dir.create(store, recursive = TRUE)
  on.exit(unlink(store, recursive = TRUE), add = TRUE)
  if (use_shm) {
    # Daemons pin every region they created for this run; release them
    # once the host is done with the results (regions outlive tasks,
    # not the run). Host-side handles die with `chunk_vals`. Both
    # pools pin regions (readers: windows; computers: results).
    on.exit(for (p in profiles)
      try(mirai::everywhere(garry::.daemon_shm_clear(), .compute = p),
          silent = TRUE), add = TRUE)
  }
  chunk_file <- function(sid, j) file.path(store, sprintf("s%d_c%d.rds", sid, j))
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
  fetch_mode <- match.arg(garry_opt("fetch"), c("auto", "direct", "force"))
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
        add_task(key, character(0), "read", launch = function() {
          mirai::mirai(
            garry::.daemon_fetch_window(src, dst, ex, cr, nodata = nd),
            src = src, dst = dst, ex = ex, cr = cr, nd = nd,
            .compute = read_prof)
        })
      })
    }
    list(deps = keys, local = st$local,
         files = st$dst[rows])
  }


  warp_only <- vapply(plan@stages, function(s) {
    consumers <- Filter(function(t2) s@id %in% t2@inputs, plan@stages)
    s@kind == "source_read" && length(consumers) > 0L &&
      all(vapply(consumers, function(t2) t2@kind == "warp", logical(1))) &&
      plan@sink != s@id
  }, logical(1))

  # Build the task table. Combine stages are host-side, handled at drain.
  tasks <- list()
  add_task <- function(key, deps, pool, launch, mb = 0) {
    tasks[[key]] <<- list(deps = deps, pool = pool, launch = launch,
                          mb = mb, state = "pending")
  }
  # For coarse-reading (split) source stages: task key per compute chunk,
  # and (mori store) each compute chunk's element name in the shared
  # parts list.
  source_deps <- new.env(parent = emptyenv())
  source_elts <- new.env(parent = emptyenv())
  # Mori store: release a read's regions once every stage consuming it
  # has finished (a region shared by several stages - e.g. the QA band
  # - must outlive all of them). Keeps the pinned working set to the
  # stages still running instead of the whole run.
  comp_stage_of <- new.env(parent = emptyenv())  # compute task -> stage
  stage_left <- new.env(parent = emptyenv())     # stage -> open chunks
  stage_reads <- new.env(parent = emptyenv())    # stage -> read tasks
  read_users <- new.env(parent = emptyenv())     # read task -> n stages

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
        rpath <- node@path; rband <- node@band; rnodata <- node@nodata
        roo <- node@open_options
      }
      skey <- .key(s@members[[1L]])
      fetch_deps <- character(0)
      if (s@kind == "source_read") {
        fp <- prepare_fetch(rpath, roo, rnodata, s@grid)
        if (!is.null(fp)) {
          fetch_deps <- fp$deps
          rpath <- fp$local
          fetch_files_of[[.key(s@id)]] <- fp$files
        }
      }
      split_cg <- .exec_split_cg(plan, s)
      if (is.null(split_cg)) {
        if (length(fetch_deps))
          fetch_reads_left[[.key(s@id)]] <- nrow(it)
        for (j in seq_len(nrow(it))) {
          local({
            sid <- s@id; jj <- j; cg <- s@chunks; core <- it[jj, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            key <- sprintf("s%d_c%d", sid, jj)
            add_task(key, fetch_deps, "read", if (use_shm) function() {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                oo = oo, reg = sprintf("r%d_%s", run_id, key),
                .compute = read_prof)
            } else function() {
              mirai::mirai(
                garry::.daemon_run_source(p2, b2, nd, cg, core, k2, out,
                                          open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                oo = oo, out = chunk_file(sid, jj),
                .compute = read_prof)
            })
          })
        }
      } else {
        # Coarse reads. RDS store: split into per-compute-chunk files on
        # write. Mori store: share the whole read buffer; consumers
        # slice their window zero-copy. Either way compute chunk j's
        # dependency is the READ task covering it.
        its <- chunk_iter(split_cg)
        H2 <- 2L * split_cg@halo
        dep_of <- character(nrow(its))
        elt_of <- sprintf("%s\x1f%d", skey, seq_len(nrow(its)))
        if (length(fetch_deps))
          fetch_reads_left[[.key(s@id)]] <- nrow(it)
        for (r in seq_len(nrow(it))) {
          members <- .exec_split_members(its, it[r, ])
          dep_of[members] <- sprintf("s%d_r%d", s@id, r)
          local({
            sid <- s@id; rr <- r; cg <- s@chunks; core <- it[rr, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            key <- sprintf("s%d_r%d", sid, rr)
            # Parts carry the stage halo (see .exec_split_cg): same
            # r0/c0, slice grown by 2*halo.
            parts <- lapply(members, function(j) {
              list(r0 = its$y_off[[j]] - core$y_off,
                   c0 = its$x_off[[j]] - core$x_off,
                   nr = its$y_size[[j]] + H2, nc = its$x_size[[j]] + H2,
                   elt = elt_of[[j]],
                   file = chunk_file(sid, j))
            })
            add_task(key, fetch_deps, "read", if (use_shm) function() {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, parts = parts,
                                              open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core,
                k2 = k2, oo = oo, parts = parts,
                reg = sprintf("r%d_%s", run_id, key),
                .compute = read_prof)
            } else function() {
              mirai::mirai(
                garry::.daemon_run_source_split(p2, b2, nd, cg, core, k2,
                                                parts, open_options = oo),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                parts = parts, oo = oo, .compute = read_prof)
            })
          })
        }
        source_deps[[.key(s@id)]] <- dep_of
        source_elts[[.key(s@id)]] <- elt_of
      }

    } else {  # compute / reduce_partial
      in_meta <- .exec_in_meta(graph, s, plan@stages)
      sig <- paste0(.stage_kernel_sig(graph, s), "@", s@device)
      okeys <- vapply(s@exports, .key, character(1))
      cd <- s@chunks@chunk_dim
      task_mb <- .stage_bytes_per_px(graph, s@members, s@input_nodes) *
        prod(as.numeric(cd) + 2 * s@halo) / 2^20
      warm_specs[[length(warm_specs) + 1L]] <- list(
        ck = sig,
        fn = s@fn,
        device = s@device,
        dtypes = vapply(in_meta, function(m) m$dtype, character(1)),
        nr = min(cd[[2L]], s@grid@dims[["y"]]) + 2L * s@halo,
        nc = min(cd[[1L]], s@grid@dims[["x"]]) + 2L * s@halo)
      for (j in seq_len(nrow(it))) {
        local({
          sid <- s@id; jj <- j; fn <- s@fn; halo <- s@halo
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
            as.integer(m$pad - halo), integer(1))
          dtypes <- vapply(meta, function(m) m$dtype, character(1))
          key <- sprintf("s%d_c%d", sid, jj)
          add_task(key, unique(in_deps), "comp", mb = task_mb,
                   launch = if (use_shm) function() {
            # Handles resolve at launch time: dependencies are done, so
            # `chunk_vals` holds every input's shared object (a ~30-byte
            # name over the wire).
            mirai::mirai(
              garry::.daemon_run_compute_shm(ck, fn, in_vals, in_keys,
                                             trims, dtypes, reg,
                                             out_keys = ok,
                                             device = dv),
              ck = ck, fn = fn,
              in_vals = lapply(in_deps, function(d) chunk_vals[[d]]),
              in_keys = shm_keys,
              trims = trims, dtypes = dtypes,
              reg = sprintf("r%d_%s", run_id, key),
              ok = out_keys, dv = sdev,
              .compute = comp_prof)
          } else function() {
            mirai::mirai(
              garry::.daemon_run_compute(ck, fn, in_files, in_keys,
                                          trims, dtypes, out,
                                          out_keys = ok,
                                          device = dv),
              ck = ck, fn = fn,
              in_files = vapply(meta, function(m)
                chunk_file(m$id, jj), character(1)),
              in_keys = in_keys,
              trims = trims, dtypes = dtypes,
              out = chunk_file(sid, jj),
              ok = out_keys, dv = sdev,
              .compute = comp_prof)
          })
          if (use_shm) {
            comp_stage_of[[key]] <- sid
            stage_left[[.key(sid)]] <-
              (stage_left[[.key(sid)]] %||% 0L) + 1L
            rk <- in_deps[grepl("_r\\d+$", in_deps)]
            stage_reads[[.key(sid)]] <-
              unique(c(stage_reads[[.key(sid)]], rk))
          }
        })
      }
    }
  }

  for (sk in ls(stage_reads))
    for (rk in stage_reads[[sk]])
      read_users[[rk]] <- (read_users[[rk]] %||% 0L) + 1L

  # Release read regions whose consuming stages have all completed.
  release_reads <- function(k) {
    sid <- comp_stage_of[[k]]
    if (is.null(sid)) return(invisible(NULL))
    sk <- .key(sid)
    stage_left[[sk]] <- stage_left[[sk]] - 1L
    if (stage_left[[sk]] > 0L) return(invisible(NULL))
    dead <- character(0)
    for (rk in stage_reads[[sk]]) {
      read_users[[rk]] <- read_users[[rk]] - 1L
      if (read_users[[rk]] == 0L) dead <- c(dead, rk)
    }
    if (length(dead) > 0L) {
      for (p in profiles)
        try(mirai::everywhere(garry::.daemon_shm_drop(regs),
                              regs = sprintf("r%d_%s", run_id, dead),
                              .compute = p),
            silent = TRUE)
      rm(list = intersect(dead, ls(chunk_vals)), envir = chunk_vals)
      gc(FALSE)   # host munmaps its handles; regions free once unlinked
    }
    invisible(NULL)
  }

  # Pre-drain jit warm-up: compile each compute stage's modal shape on
  # every compute-pool daemon while the read pool owns the drain
  # (measured: cold 1.45 s vs warmed 0.61 s per tail chunk). Fired
  # async — a daemon runs it before any compute task queued after it;
  # the handle stays referenced until the run ends. Only in pooled
  # mode: on a shared pool the warm task would displace a read (the
  # phase 10 rejection).
  warm_handle <- NULL
  if (pooled && isTRUE(garry_opt("jit_warmup")) && length(warm_specs)) {
    # Content-addressed keys collapse structurally identical stages
    # (e.g. per-slice mask cleanup) to ONE spec.
    warm_specs <- warm_specs[!duplicated(
      vapply(warm_specs, `[[`, character(1), "ck"))]
    warm_handle <- mirai::everywhere(garry::.daemon_warm_jit(sp),
                                     sp = warm_specs,
                                     .compute = comp_prof)
  }

  # Streaming sink writes (phase 11.3): with a file destination, each
  # sink chunk writes the moment it lands, so all but the last band's
  # writes hide under the drain instead of running serially after it.
  # (On error the partially written file is left behind; the
  # single-threaded executor still writes at the end.)
  sink <- plan@stages[[plan@sink]]
  stream_write <- !is.null(path) && sink@kind != "reduce_combine"
  sink_ds <- NULL
  if (stream_write) {
    sink_skey <- .key(sink@members[[length(sink@members)]])
    sink_it <- chunk_iter(sink@chunks)
    sink_spad <- .exec_out_pad(sink)
    wnodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
    sink_task_j <- stats::setNames(
      seq_len(nrow(sink_it)),
      sprintf("s%d_c%d", sink@id, seq_len(nrow(sink_it))))
    sink_ds <- gdal_create_output(path, sink@grid, nodata = wnodata)
    on.exit(if (!is.null(sink_ds)) try(sink_ds$close(), silent = TRUE),
            add = TRUE)
  }

  # Polling ready-queue with per-pool in-flight caps; compute
  # launches additionally gated by the byte budget (always at least
  # one runs, so a single over-budget task cannot deadlock).
  inflight <- list()
  n_inflight <- c(read = 0L, comp = 0L)
  mb_inflight <- 0
  comp_ok <- function(t) {
    n_inflight[["comp"]] < cap_comp &&
      (n_inflight[["comp"]] == 0L ||
         mb_inflight + t$mb <= comp_budget_mb)
  }
  done <- character(0)
  is_ready <- function(t) all(t$deps %in% done)
  remaining <- function() {
    any(vapply(tasks, function(t) t$state != "done", logical(1)))
  }
  progress <- isTRUE(garry_opt("progress"))
  task_log <- garry_opt("task_log")
  log_line <- if (is.null(task_log)) function(...) NULL else {
    function(event, key) cat(sprintf("%.3f,%s,%s\n", unclass(Sys.time()),
                                     event, key),
                             file = task_log, append = TRUE)
  }
  n_total <- length(tasks)
  last_report <- Sys.time()
  while (remaining()) {
    for (k in names(tasks)) {
      # Single pool: one shared bucket (pre-pool behavior). Pooled:
      # reads and computes throttle independently, so a saturated
      # read queue never blocks compute launches or vice versa.
      if (!pooled && length(inflight) >= cap_read) break
      t <- tasks[[k]]
      if (t$state != "pending") next
      if (pooled) {
        if (t$pool == "read" && n_inflight[["read"]] >= cap_read) next
        if (t$pool == "comp" && !comp_ok(t)) next
      }
      if (!is_ready(t)) next
      inflight[[k]] <- t$launch()
      n_inflight[[t$pool]] <- n_inflight[[t$pool]] + 1L
      if (t$pool == "comp") mb_inflight <- mb_inflight + t$mb
      tasks[[k]]$state <- "running"
      log_line("launch", k)
    }
    if (length(inflight) == 0L)
      .garry_error("scheduler deadlock: no runnable tasks",
                   "garry_scheduler_error")
    harvested <- FALSE
    for (k in names(inflight)) {
      h <- inflight[[k]]
      if (!mirai::unresolved(h)) {
        if (inherits(h$data, c("miraiError", "errorValue")))
          stop("task ", k, " failed on daemon: ", as.character(h$data))
        if (use_shm) chunk_vals[[k]] <- h$data
        tasks[[k]]$state <- "done"
        done <- c(done, k)
        inflight[[k]] <- NULL
        pool_k <- tasks[[k]]$pool
        n_inflight[[pool_k]] <- n_inflight[[pool_k]] - 1L
        if (pool_k == "comp") mb_inflight <- mb_inflight - tasks[[k]]$mb
        harvested <- TRUE
        log_line("done", k)
        if (stream_write && !is.na(sink_task_j[k])) {
          j <- sink_task_j[[k]]
          ch <- if (use_shm) chunk_vals[[k]][[sink_skey]]
                else readRDS(chunk_file(sink@id, j))[[sink_skey]]
          .exec_check_writable(ch, nrow(sink_it))
          .exec_write_chunk(sink_ds, sink_it$x_off[j], sink_it$y_off[j],
                            ch, sink_spad, sink@grid@dtype, wnodata)
          log_line("write", k)
        }
        if (use_shm) release_reads(k)
        # Eager fetch-cache cleanup: a fetch-backed source stage's
        # window files unlink once its last read (assemble) task is
        # done — bounds the tmpfs cache to slices still assembling.
        if (pool_k == "read" && startsWith(k, "s")) {
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
    if (progress &&
        difftime(Sys.time(), last_report, units = "secs") > 5) {
      cat(sprintf("  garry: %d/%d tasks done, %d in flight\n",
                  length(done), n_total, length(inflight)))
      last_report <- Sys.time()
    }
    if (!harvested) Sys.sleep(0.002)
  }

  # Host-side: combines, then sink retrieval (mirrors execute_plan).
  # Sink/combine stages are never split-read sources (splits only exist
  # under a compute consumer), so chunk-keyed lookup always resolves.
  log_line("drain_end", "-")
  on.exit(log_line("host_end", "-"), add = TRUE)
  read_chunk <- function(sid, j) {
    if (use_shm) chunk_vals[[sprintf("s%d_c%d", sid, j)]]
    else readRDS(chunk_file(sid, j))
  }
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
    partials <- lapply(out_of(part), `[[`, key)
    combine_vals[[.key(s@id)]] <- s@fn(partials)
  }

  key <- .key(sink@members[[length(sink@members)]])
  chunks <- if (sink@kind == "reduce_combine") {
    list(combine_vals[[.key(sink@id)]][[key]])
  } else {
    lapply(out_of(sink), `[[`, key)
  }
  it <- chunk_iter(sink@chunks)
  sink_pad <- .exec_out_pad(sink)

  if (!is.null(path))
    return(.exec_write_sink(chunks, it, sink, path, nodata))

  if (nrow(it) == 1L) {
    v <- chunks[[1L]]
    if (is.matrix(v)) v <- .exec_trim(v, sink_pad)
    if (is.matrix(v) && all(dim(v) == c(1L, 1L))) return(v[1L, 1L])
    return(v)
  }
  .exec_assemble(chunks, it, sink@grid, sink_pad)
}
