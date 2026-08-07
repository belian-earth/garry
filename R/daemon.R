#' @include executor.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Daemon-side code: every function that executes IN a mirai daemon
# process, addressed cross-process via `garry::` — the .daemon_*
# family, the composite-direct task bodies, memory hygiene, and the
# ABI token that guards host/daemon namespace skew. Keeping every
# cross-process entry point in one file is what keeps the ABI
# enrollment honest (deep review 2026-08-02): a body added here is a
# body the skew check covers.
# ---------------------------------------------------------------------------

# Per-process cache used on daemons (jitted stage closures by stage id).
.daemon_cache <- new.env(parent = emptyenv())

# Return freed heap pages to the OS (glibc malloc_trim(0); no-op
# elsewhere). The scan-retention spike (benchmarks/scan-retention-
# spike.R, 2026-08-01) measured a scan daemon standing at 904 MB of
# which 475 MB was trimmable glibc arena and 72 MB evictable jit
# handles — the "retained scan working set" that walls off wide scan
# pools is mostly memory nobody holds. Called after every compute/write
# task (µs-cheap) and by .daemon_hygiene.
.garry_malloc_trim <- function() {
  .Call("garry_malloc_trim", PACKAGE = "garry")
}

#' Daemon task body: memory hygiene — trim arenas, optionally evict the
#' jit cache.
#'
#' `deep = TRUE` additionally clears the jit cache (forces recompiles:
#' ~1 s for map kernels, ~20 s for scans) — reserve it for memory
#' pressure; the default trim-only pass costs microseconds and gives
#' back what glibc is hoarding.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#' @param deep Also evict the jit cache?
#' @return `TRUE` if the trim ran (glibc), invisibly.
#' @keywords internal
#' @export
.daemon_hygiene <- function(deep = FALSE) {
  if (isTRUE(deep)) {
    e <- .daemon_cache
    rm(list = ls(e), envir = e)
  }
  gc(FALSE)
  invisible(.garry_malloc_trim())
}

# Store layout ABI version: bump on any incompatible change to the raw
# payload byte layout, region naming, or shared-value envelope.
.garry_store_abi <- 1L

#' Daemon-facing ABI token: a hash of every `.daemon_*` entry point's
#' formals plus the store layout version.
#'
#' Daemons resolve `garry::.daemon_*` from their INSTALLED library while
#' a development host frequently runs a `load_all()` tree; a namespace
#' skew yields "unused argument" mirai errors at best and silent
#' semantic drift at worst (positional renames, new masking arguments).
#' `packageVersion()` cannot guard this (constant through development);
#' the formals can. Internal (exported so daemons can evaluate their
#' own token via `::`).
#'
#' @return A single hash string.
#' @keywords internal
#' @export
.garry_abi_token <- function() {
  ns <- asNamespace("garry")
  # Every cross-process entry point must be enrolled: the .daemon_*
  # family by pattern, plus composite_direct's task bodies, which are
  # invoked via garry:: on daemons but named .cd_*/.gd_* (deep review
  # 2026-08-02: they previously escaped the hash, so .gd_daemon_prep's
  # skew check passed under skew).
  nms <- sort(c(ls(ns, all.names = TRUE, pattern = "^\\.daemon_"),
                ".cd_fetch_warp", ".gd_warm", ".gd_compute_mask",
                ".gd_compute_masked_band"))
  nms <- nms[vapply(nms, function(n)
    exists(n, envir = ns) && is.function(get(n, envir = ns)),
    logical(1))]
  rlang::hash(list(
    store = .garry_store_abi,
    formals = stats::setNames(
      lapply(nms, function(n) formals(get(n, envir = ns))), nms)))
}

# Compare the host ABI token against each pool's, once per pool
# generation (garry_daemons() clears the cache). A daemon running last
# week's installed scheduler against today's host tree is otherwise
# undefined behavior mid-drain.
.garry_abi_check <- function(profiles) {
  if (isTRUE(.garry_state$abi_ok)) return(invisible(NULL))
  host <- .garry_abi_token()
  for (p in profiles) {
    d <- tryCatch(mirai::mirai(garry::.garry_abi_token(), .compute = p)[],
                  error = function(e) NA_character_)
    if (inherits(d, "miraiError") || !is.character(d)) d <- NA_character_
    if (!identical(d, host))
      .garry_error(paste0(
        "host/daemon ABI skew on pool '", p, "' (host ", host,
        ", daemon ", if (is.na(d)) "unknown/pre-token" else d, "): ",
        "the daemons run the installed garry, the host a different tree. ",
        "Run devtools::install() and restart the pools (garry_daemons())."),
        "garry_version_skew_error")
  }
  .garry_state$abi_ok <- TRUE
  invisible(NULL)
}

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
  # f32/f64 kernel outputs become raw store payloads directly off the
  # device (D19; f64 per design/f64-store.md): no double
  # materialisation on the download either.
  out <- if (store_raw && .g_dtype(out_dev) %in% c("f32", "f64")) {
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
                                   store_raw = FALSE,
                                   scale = numeric(0), offset = numeric(0)) {
  m <- .exec_read_padded(path, band, nodata, cg, core,
                         open_options = open_options,
                         out = if (read_raw) "raw_f32" else "matrix",
                         scale = scale, offset = offset)
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

# Writer-daemon open-output cache: path -> GDALRaster (update mode).
# Lives for the run; the host closes it with .daemon_write_close.
.daemon_ds <- new.env(parent = emptyenv())

#' Daemon task body: write one sink chunk window to an output file.
#'
#' The streamed-sink write, moved OFF the host dispatch thread: the
#' host creates the output (geometry, bands, nodata) and ships only
#' the mori region NAME plus window coordinates; this body maps the
#' region, extracts the chunk, materialises/converts it and runs the
#' GDAL write — so the multi-GB conversion transients (f64 scan sinks
#' cannot ride the raw f32 store) live in one lean process that is
#' reaped per task, not on the thread that launches and harvests every
#' other task. One writer daemon per session: GTiff is single-writer,
#' and daemon-persistent open handles amortise the opens.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path Output file (already created by the host).
#' @param x_off,y_off Window offsets.
#' @param val Shared store value; `el` names the element for split
#'   coarse-read parts, else `skey` (the export node key) extracts.
#' @param skey,el Extraction keys.
#' @param pad,dtype,nodata,n_chunks As the host-side write path.
#' @return `TRUE`.
#' @keywords internal
#' @export
.daemon_write_chunk <- function(path, x_off, y_off, val, skey, el,
                                pad, dtype, nodata, n_chunks) {
  ds <- .daemon_ds[[path]]
  if (is.null(ds)) {
    ds <- gdal_open_update(path)
    .daemon_ds[[path]] <- ds
  }
  ch <- if (is.null(el)) val[[skey]] else val[[el]]
  .exec_check_writable(ch, n_chunks)
  .exec_write_chunk(ds, x_off, y_off, ch, pad, dtype, nodata)
  rm(ch, val)
  gc(FALSE)
  .garry_malloc_trim()
  TRUE
}

#' Daemon task body: close every output the writer holds open.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @return `NULL`, invisibly.
#' @keywords internal
#' @export
.daemon_write_close <- function() {
  for (p in ls(.daemon_ds)) try(.daemon_ds[[p]]$close(), silent = TRUE)
  rm(list = ls(.daemon_ds), envir = .daemon_ds)
  gc(FALSE)
  invisible(NULL)
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
    .gdal_with_retry(function()
      gdal_fetch_window(location, out_file, ext, crs, margin = margin,
                        out_res = target_res),
      what = "fetch"),
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
  # return to the OS (see benchmarks/hls-median-composite.R). The env
  # thresholds only cover the top-of-heap path; malloc_trim(0) walks
  # every arena, and the scan-retention spike measured the difference
  # at ~475 MB of standing arena per scan daemon.
  rm(inputs, res)
  gc(FALSE)
  .garry_malloc_trim()
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

# -- composite-direct daemon task bodies --------------------------------------

# Warm a daemon's XLA/PJRT client (one trivial jit) so the first real compute
# task doesn't pay the ~3s cold init on the critical path.
#' @keywords internal
#' @export
.gd_warm <- function() {
  .require_anvl()
  a <- g_upload_raw(writeBin(as.numeric(1:4), raw(), size = 4L), "f32", c(2L, 2L))
  g_download(g_jit(function(inp) inp[[1L]] + 1)(list(a)))
  invisible(TRUE)
}

# Pipeline daemon task: replay the cleaned mask ONCE on the whole fmask cube
# (morphology, cube-vectorised over time) and write the resulting f32 mask cube
# to one .bin, so every band's median reads it instead of recomputing the
# morphology. Runs on the compute pool while the bands are still fetching.
#' @keywords internal
#' @export
.gd_compute_mask <- function(k) {
  .require_anvl()
  dev <- .exec_device(k$dev)
  n <- length(k$fmask_bins)
  fm <- g_upload_raw(
    do.call(c, lapply(k$fmask_bins, function(f) readBin(f, "raw", n = k$ny * k$nx * 4L))),
    "f32", c(n, k$ny, k$nx), device = dev)
  cleaned <- g_jit(function(inp)
    .gd_replay_mask(inp[[1L]], k$chain, k$halo, k$ny, k$nx), device = dev)(list(fm))
  r <- g_download_raw(cleaned); attributes(r) <- NULL
  writeBin(r, k$out_bin)                       # whole cube, row-major f32
  invisible(TRUE)
}

# Pipeline daemon task: one band's median. Reads the band cube plus the shared
# cleaned-mask cube (already morphology-processed by .gd_compute_mask), applies
# the masked-apply fn F, and reduces over time -> (ny,nx) raw f32 payload. Runs
# on the compute pool while later bands are still fetching.
#' @keywords internal
#' @export
.gd_compute_masked_band <- function(job, k) {
  .require_anvl()
  dev <- .exec_device(k$dev)
  n <- length(job$band_bins)
  cube <- function(bins) g_upload_raw(
    do.call(c, lapply(bins, function(f) readBin(f, "raw", n = k$ny * k$nx * 4L))),
    "f32", c(length(bins), k$ny, k$nx), device = dev)
  band <- cube(job$band_bins)
  masked <- length(k$mask_bin) == 1L
  # Read affine (SourceNode scale/offset), applied to the DN cube before the
  # masked-apply so the kernel sees what a scaled read would have produced.
  aff <- job$affine
  adj <- if (!is.null(aff) && length(aff$scale) == 1L)
    function(x) x * aff$scale + aff$offset else identity
  if (masked) {
    mask <- g_upload_raw(readBin(k$mask_bin, "raw", n = n * k$ny * k$nx * 4L),
                         "f32", c(n, k$ny, k$nx), device = dev)
    lean <- function(inp) .apply_reduce(k$op, k$F(adj(inp[[1L]]), inp[[2L]]), 1L, k$nan_rm)
    g_download_raw(g_jit(lean, device = dev)(list(band, mask)))
  } else {
    lean <- function(inp) .apply_reduce(k$op, adj(inp[[1L]]), 1L, k$nan_rm)
    g_download_raw(g_jit(lean, device = dev)(list(band)))
  }
}

# One source's warp-on-read, run in a daemon: warp this slice's REMOTE item
# window(s) straight into a raw f32 buffer via MEM:::DATAPOINTER in one
# gdalwarp -- GDAL reads (windowed vsicurl), reprojects and mosaics the sources
# itself, writing f32 into memory we hold (no R double, no tmpfs GTiff, no
# local index). Writes the payload to `bin`.
# `j` carries only this slice's varying data (locs, dt, nodata, bin); `k` is
# the grid-constant bundle passed once via mirai `.args` (embedding it in every
# task instead throttles the dispatcher and starves the daemon pool).
#' Daemon task body: warp one slice's remote items into an f32 buffer.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#' @param j Per-slice job (locs/dt/nodata/resampling/bin).
#' @param k Grid-constant bundle (nx/ny/gtstr/wkt).
#' @return List with `err`, `tf`, `tw`.
#' @keywords internal
#' @export
.cd_fetch_warp <- function(j, k) {
  nx <- k$nx; ny <- k$ny
  buf <- rep(writeBin(NaN, raw(), size = 4L), nx * ny)   # all-nodata default
  tw <- 0
  err <- tryCatch({
    if (!length(j$locs)) cli::cli_abort("no items for this slice")
    # WARP-ON-READ (via the adapter): warp the slice's REMOTE items straight
    # into the f32 buffer in one gdalwarp -- GDAL reads (windowed vsicurl),
    # reprojects and mosaics the sources itself. No tmpfs GTiff fetch, no
    # per-slice local index. Ordered by datetime so overlap resolution (last
    # source wins) matches the GTI SORT_FIELD=datetime, highest-on-top path.
    tw <- system.time(
      buf <- .gdal_with_retry(function()
        gdal_warp_to_buffer(buf, nx, ny, k$gtstr, k$wkt,
                            j$locs[order(j$dt)], j$nodata,
                            resampling = j$resampling %||% "near"),
        what = "slice warp")
    )[["elapsed"]]
    NA_character_
  }, error = function(e) conditionMessage(e))
  writeBin(buf, j$bin)   # always write a complete slice (real or all-NaN)
  list(err = err, tf = 0, tw = tw)
}
