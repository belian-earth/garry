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
    rm(list = ls(e, all.names = TRUE), envir = e)
  }
  gc(FALSE)
  invisible(.garry_malloc_trim())
}

# Store layout ABI version: bump on any incompatible change to the raw
# payload byte layout, region naming, or shared-value envelope.
.garry_store_abi <- 2L # 2: sink-only integer payloads (g_quantize)

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
  nms <- sort(c(
    ls(ns, all.names = TRUE, pattern = "^\\.daemon_"),
    ".cd_fetch_warp",
    ".gd_warm",
    ".gd_warm_pipeline",
    ".gd_compute_mask",
    ".gd_compute_masked_band"
  ))
  nms <- nms[vapply(
    nms,
    function(n) {
      exists(n, envir = ns) && is.function(get(n, envir = ns))
    },
    logical(1)
  )]
  rlang::hash(list(
    store = .garry_store_abi,
    formals = stats::setNames(
      lapply(nms, function(n) formals(get(n, envir = ns))),
      nms
    )
  ))
}

# Compare the host ABI token against each pool's, once per pool
# generation (garry_daemons() clears the cache). A daemon running last
# week's installed scheduler against today's host tree is otherwise
# undefined behavior mid-drain.
.garry_abi_check <- function(profiles) {
  if (isTRUE(.garry_state$abi_ok)) {
    return(invisible(NULL))
  }
  host <- .garry_abi_token()
  for (p in profiles) {
    d <- tryCatch(
      mirai::mirai(garry::.garry_abi_token(), .compute = p)[],
      error = function(e) NA_character_
    )
    if (inherits(d, "miraiError") || !is.character(d)) {
      d <- NA_character_
    }
    if (!identical(d, host)) {
      .garry_error(
        paste0(
          "host/daemon ABI skew on pool '",
          p,
          "' (host ",
          host,
          ", daemon ",
          if (is.na(d)) "unknown/pre-token" else d,
          "): ",
          "the daemons run the installed garry, the host a different tree. ",
          "Run devtools::install() and restart the pools (garry_daemons())."
        ),
        "garry_version_skew_error"
      )
    }
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
  rm(list = ls(.daemon_shm, all.names = TRUE), envir = .daemon_shm)
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
  keys <- intersect(keys, ls(.daemon_shm, all.names = TRUE))
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
  if (length(ls(.daemon_cache, all.names = TRUE)) > 64L) {
    rm(list = ls(.daemon_cache, all.names = TRUE), envir = .daemon_cache)
  }
  jf <- .daemon_cache[[fuse$ck]]
  if (is.null(jf)) {
    jf <- g_jit(fuse$fn)
    .daemon_cache[[fuse$ck]] <- jf
  }
  up <- if (.sv_is(m)) {
    g_upload_raw(m, "f32", .sv_dim(m))
  } else {
    g_upload(m, fuse$dtype)
  }
  res <- jf(list(up))
  out_dev <- res[[1L]]
  # Producer-side write quantization for a FUSED sink (the host sets
  # fuse$wq only when this fused export is a no-other-consumer sink).
  # Applied eagerly on device, outside the jitted kernel, so the
  # content-addressed kernel cache key is untouched.
  if (!is.null(fuse$wq)) {
    out_dev <- g_quantize(
      out_dev,
      fuse$wq$scale,
      fuse$wq$offset,
      fuse$wq$nodata,
      fuse$wq$dtype
    )
  }
  # f32/f64 kernel outputs become raw store payloads directly off the
  # device (D19; f64 per design/f64-store.md); quantized sink outputs
  # ride the same raw path as integer payloads.
  out <- if (
    store_raw &&
      .g_dtype(out_dev) %in% c("f32", "f64", "u8", "i8", "i16", "u16", "i32")
  ) {
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
#' matrix would materialise the whole window per input, a large
#' transient allocation, so the split happens producer-side here too.)
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @param path,band,nodata Source identity.
#' @param cg `ChunkGrid`; `core` the chunk row; `key` the node key;
#'   `reg_key` the daemon registry slot pinning the region.
#' @param parts NULL for chunk-aligned reads (the buffer is shared
#'   whole under `key`), else per-compute-chunk windows (`r0`/`c0`
#'   0-based offsets, `nr`/`nc` sizes, `elt` the element name).
#' @param decim Optional decimating-read spec (see [gdal_read_window()]),
#'   set when an aligned warp is served by a direct RasterIO read.
#' @return The shared object (serialises as its region name).
#' @keywords internal
#' @export
.daemon_run_source_shm <- function(
  path,
  band,
  nodata,
  cg,
  core,
  key,
  reg_key,
  parts = NULL,
  open_options = character(0),
  fuse = NULL,
  read_raw = FALSE,
  store_raw = FALSE,
  scale = numeric(0),
  offset = numeric(0),
  decim = NULL
) {
  m <- .exec_read_padded(
    path,
    band,
    nodata,
    cg,
    core,
    open_options = open_options,
    out = if (read_raw) "raw_f32" else "matrix",
    scale = scale,
    offset = offset,
    decim = decim
  )
  if (!is.null(fuse)) {
    m <- .apply_fuse(m, fuse, store_raw)
    if ((fuse$out_pad %||% 0L) > 0L) {
      m <- .exec_mask_edge(m, fuse$out_pad, core, cg@grid@dims)
    }
  }
  val <- if (is.null(parts)) {
    stats::setNames(list(m), key)
  } else if (.sv_is(m)) {
    slc <- .sv_slicer(m)
    stats::setNames(
      lapply(parts, function(p) slc(p$r0, p$c0, p$nr, p$nc)),
      vapply(parts, `[[`, character(1), "elt")
    )
  } else {
    rank3 <- length(dim(m)) == 3L # multi-band (band, y, x) window
    stats::setNames(
      lapply(parts, function(p) {
        if (rank3) {
          m[,
            (p$r0 + 1L):(p$r0 + p$nr),
            (p$c0 + 1L):(p$c0 + p$nc),
            drop = FALSE
          ]
        } else {
          m[(p$r0 + 1L):(p$r0 + p$nr), (p$c0 + 1L):(p$c0 + p$nc), drop = FALSE]
        }
      }),
      vapply(parts, `[[`, character(1), "elt")
    )
  }
  sh <- mori::share(val)
  .daemon_shm[[reg_key]] <- sh
  # Reader-side hygiene, mirroring the compute/write bodies: the read
  # window and its part list are dead once copied into shm, and the
  # native churn under the read (curl/TLS/PROJ) leaves freed arena
  # pages nothing else returns to the OS (the 11.1 drain plateau).
  rm(m, val)
  gc(FALSE)
  .garry_malloc_trim()
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
.daemon_write_chunk <- function(
  path,
  x_off,
  y_off,
  val,
  skey,
  el,
  pad,
  dtype,
  nodata,
  n_chunks
) {
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
  # all.names: the cache is keyed by OUTPUT PATH, and ls() hides
  # dot-prefixed names by default -- a "./out.tif" key (every cog=TRUE
  # temp under a relative path) was invisible here, so its dataset was
  # never closed and the file stayed an unflushed zero-filled shell
  # (diagnosed 2026-08-13: pools + relative path + cog wrote "all
  # zeros" while the data sat in the writer's block cache).
  ks <- ls(.daemon_ds, all.names = TRUE)
  for (p in ks) {
    try(.daemon_ds[[p]]$close(), silent = TRUE)
  }
  rm(list = ks, envir = .daemon_ds)
  gc(FALSE)
  invisible(NULL)
}

#' Daemon task body: fetch one item-asset's target-window bytes to a
#' local file.
#'
#' The fetch half of the fetch/assemble split: a plain
#' `gdal_translate -srcwin` of the window intersecting the target
#' extent (plus a warp-kernel margin), remote COG to local tmpfs,
#' native dtype and blocks; no warp, no mosaic on the remote path.
#' On failure with `garry.read_fail = "nodata"`, writes a small
#' all-nodata placeholder covering the window so the local mosaic
#' reads a hole instead of erroring (Int16 when a nodata sentinel is
#' declared, Byte 255 otherwise, the HLS QA convention).
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
.daemon_fetch_window <- function(
  location,
  out_file,
  ext,
  crs,
  nodata = numeric(0),
  margin = 8L,
  target_res = NULL
) {
  ok <- tryCatch(
    .gdal_with_retry(
      function() {
        gdal_fetch_window(
          location,
          out_file,
          ext,
          crs,
          margin = margin,
          out_res = target_res
        )
      },
      what = "fetch"
    ),
    error = function(e) e
  )
  if (!isTRUE(ok)) {
    if (!identical(garry_opt("read_fail"), "nodata")) {
      cli::cli_abort("fetch failed: {location} ({conditionMessage(ok)})")
    }
    cli::cli_warn(
      "fetch failed, writing nodata window: {location} ({conditionMessage(ok)})"
    )
    unlink(out_file)
    gdal_nodata_window(out_file, ext, crs, nodata)
  }
  .garry_malloc_trim()
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
.daemon_run_compute_shm <- function(
  cache_key,
  fn,
  in_vals,
  in_keys,
  trims,
  dtypes,
  reg_key,
  out_keys = NULL,
  device = "cpu",
  store_raw = FALSE,
  edge = NULL,
  wq = NULL
) {
  if (length(ls(.daemon_cache, all.names = TRUE)) > 64L) {
    rm(list = ls(.daemon_cache, all.names = TRUE), envir = .daemon_cache)
  }
  dev <- .exec_device(device)
  jf <- .daemon_cache[[cache_key]]
  if (is.null(jf)) {
    # The host sends fn = NULL for cache keys the pre-drain warm-up
    # broadcast to this pool (the stage closure serializes at MBs per
    # task otherwise). A miss with no fn (warm-up failed, cache
    # evicted) signals the host to resend the task WITH the closure.
    if (is.null(fn)) {
      stop("garry_jit_miss: stage closure not cached on this daemon")
    }
    jf <- g_jit(fn, device = dev)
    .daemon_cache[[cache_key]] <- jf
  }
  inputs <- Map(
    function(v, k, tr, dt) {
      .sv_upload(v[[k]], tr, dt, dev)
    },
    in_vals,
    in_keys,
    trims,
    dtypes
  )
  dev_res <- jf(unname(inputs))
  # Producer-side write quantization (g_quantize, the one quantizer):
  # `wq$keys` names the sink exports the host cleared for it (sink
  # nodes with NO other consumers -- a store value another stage still
  # reads must stay f32). Positions resolve through out_keys (the
  # content-addressed cache renames exports positionally after).
  if (!is.null(wq) && length(wq$keys)) {
    pos <- match(wq$keys, out_keys %||% names(dev_res))
    for (p2 in pos[!is.na(pos)]) {
      dev_res[[p2]] <- g_quantize(
        dev_res[[p2]],
        wq$scale,
        wq$offset,
        wq$nodata,
        wq$dtype
      )
    }
  }
  res <- .sv_download_exports(dev_res, store_raw)
  # Content-addressed cache keys share one jitted wrapper across
  # structurally identical stages; the wrapper's export NAMES belong
  # to whichever stage compiled it, so rename positionally (exports
  # are ascending in every composed closure).
  if (!is.null(out_keys)) {
    names(res) <- out_keys
  }
  if (!is.null(edge)) {
    for (k in names(edge$pads)) {
      res[[k]] <- .exec_mask_edge(
        res[[k]],
        edge$pads[[k]],
        edge$core,
        edge$gdims
      )
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
#' compile never lands on a tail chunk.
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
    tryCatch(
      {
        dev <- .exec_device(sp$device %||% "cpu")
        jf <- .daemon_cache[[sp$ck]]
        if (is.null(jf)) {
          jf <- g_jit(sp$fn, device = dev)
          .daemon_cache[[sp$ck]] <- jf
        }
        obs <- sp$outers %||% rep(1L, length(sp$dtypes))
        dummy <- Map(
          function(dt, ob) {
            if (ob > 1L) {
              g_upload(array(0, c(ob, sp$nr, sp$nc)), dt, device = dev)
            } else {
              g_upload(matrix(0, sp$nr, sp$nc), dt, device = dev)
            }
          },
          sp$dtypes,
          obs
        )
        invisible(g_download(jf(unname(dummy))))
        rm(dummy)
      },
      error = function(e) NULL
    )
  }
  gc(FALSE)
  invisible(NULL)
}

# -- composite-direct daemon task bodies --------------------------------------

# Warm a daemon's XLA/PJRT client (one trivial jit) so the first real compute
# task doesn't pay the ~3s cold init on the critical path.
#' Daemon task body: warm this daemon's XLA/PJRT client.
#'
#' Runs one trivial jitted kernel so the first real compute task does
#' not pay the cold client initialisation.
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @keywords internal
#' @export
.gd_warm <- function() {
  .require_anvl()
  a <- g_upload_raw(
    writeBin(as.numeric(1:4), raw(), size = 4L),
    "f32",
    c(2L, 2L)
  )
  g_download(g_jit(function(inp) inp[[1L]] + 1)(list(a)))
  invisible(TRUE)
}

# Pipeline JitFunction creations in this process (tests + progress lines).
.gd_jit_stats <- new.env(parent = emptyenv())

#' Daemon task body: pipeline JitFunctions created in this process so far.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#' @return Integer count.
#' @keywords internal
#' @export
.daemon_jit_creates <- function() .gd_jit_stats$creates %||% 0L

# Get-or-create a content-addressed JitFunction for a pipeline kernel.
# The dispatcher cache anvl hangs off a JitFunction is keyed on input
# shapes only, never the function, so an inline g_jit per task recompiles
# every time; caching the JitFunction under a host-computed content key
# (everything the traced closure closes over) is what lets same-kernel
# tasks share one dispatcher and hit anvl's shape LRU. ck = NULL keeps
# the inline behaviour.
.gd_cached_jit <- function(ck, fn, dev) {
  if (is.null(ck)) {
    return(g_jit(fn, device = dev))
  }
  if (length(ls(.daemon_cache, all.names = TRUE)) > 64L) {
    rm(list = ls(.daemon_cache, all.names = TRUE), envir = .daemon_cache)
  }
  jf <- .daemon_cache[[ck]]
  if (is.null(jf)) {
    jf <- g_jit(fn, device = dev)
    .daemon_cache[[ck]] <- jf
    .gd_jit_stats$creates <- (.gd_jit_stats$creates %||% 0L) + 1L
  }
  jf
}

# Rebuild the lean band kernel from a spec. Shared by the real task body
# and the warm-up so both produce semantically identical closures for one
# ck (the ck hashes exactly these ingredients: F, op, nan_rm, affine,
# masked, device).
.gd_lean_fn <- function(F, op, nan_rm, affine, masked) {
  adj <- if (!is.null(affine) && length(affine$scale) == 1L) {
    sc <- affine$scale
    of <- affine$offset
    function(x) x * sc + of
  } else {
    identity
  }
  if (masked) {
    function(inp) .apply_reduce(op, F(adj(inp[[1L]]), inp[[2L]]), 1L, nan_rm)
  } else {
    function(inp) .apply_reduce(op, adj(inp[[1L]]), 1L, nan_rm)
  }
}

#' Daemon task body: pre-compile the pipeline lean kernels.
#'
#' Runs on each compute-pool daemon while the read pool owns the fetch
#' drain: get-or-create each spec's JitFunction under the same `ck` the
#' real band tasks use, then execute once per strip height on `g_fill`
#' dummies (the fill is represented in the program — no host bytes move)
#' so the XLA compile never lands on the post-fetch tail. Failures fall
#' back to the plain client wake; warm-up is an optimisation, never a
#' correctness dependency.
#'
#' Internal (exported only so mirai daemons can address it via `::`).
#' @param specs List of kernel specs: `ck`, `F`, `op`, `nan_rm`,
#'   `affine`, `masked`, `dev`, `n` slice count, `hs` strip heights, `nx`.
#' @return `NULL`, invisibly.
#' @keywords internal
#' @export
.gd_warm_pipeline <- function(specs) {
  ok <- tryCatch(
    {
      .require_anvl()
      for (sp in specs) {
        dev <- .exec_device(sp$dev)
        jf <- .gd_cached_jit(
          sp$ck,
          .gd_lean_fn(sp$F, sp$op, sp$nan_rm, sp$affine, sp$masked),
          dev
        )
        for (h in sp$hs) {
          dims <- c(sp$n, h, sp$nx)
          inputs <- if (sp$masked) {
            list(g_fill(0, dims, "f32", dev), g_fill(0, dims, "f32", dev))
          } else {
            list(g_fill(0, dims, "f32", dev))
          }
          invisible(g_download_raw(jf(inputs)))
          rm(inputs)
        }
      }
      TRUE
    },
    error = function(e) FALSE
  )
  if (!ok) {
    try(.gd_warm(), silent = TRUE)
  }
  gc(FALSE)
  invisible(NULL)
}

# Pipeline daemon task: replay the cleaned mask ONCE on the whole fmask cube
# (morphology, cube-vectorised over time) and write the resulting f32 mask cube
# to one .bin, so every band's median reads it instead of recomputing the
# morphology. Runs on the compute pool while the bands are still fetching.
#' Daemon task body: compute the shared cleaned-mask cube.
#'
#' Replays the mask-cleaning morphology once over the whole QA cube and
#' writes the resulting f32 mask cube to a file every band task reads,
#' instead of recomputing the morphology per band.
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @keywords internal
#' @export
.gd_compute_mask <- function(k) {
  .require_anvl()
  dev <- .exec_device(k$dev)
  n <- length(k$fmask_bins)
  fm <- g_upload_raw(
    do.call(
      c,
      lapply(k$fmask_bins, function(f) readBin(f, "raw", n = k$ny * k$nx * 4L))
    ),
    "f32",
    c(n, k$ny, k$nx),
    device = dev
  )
  chain <- k$chain
  halo <- k$halo
  nyy <- k$ny
  nxx <- k$nx
  jf <- .gd_cached_jit(
    k$ck,
    function(inp) {
      .gd_replay_mask(inp[[1L]], chain, halo, nyy, nxx)
    },
    dev
  )
  r <- g_download_raw(jf(list(fm)))
  attributes(r) <- NULL
  writeBin(r, k$out_bin) # whole cube, row-major f32
  invisible(TRUE)
}

# Pipeline daemon task: one band's median (whole grid, or one horizontal
# strip when `job$rows = c(y0, h)` is set — the bins are headerless
# row-major f32, so a strip is a contiguous run at `y0*nx*4` per slice
# and the median is spatially pointwise: no halo, byte-identical
# reassembly). Reads the band cube plus the shared cleaned-mask cube
# (already morphology-processed by .gd_compute_mask), applies the
# masked-apply fn F, and reduces over time -> (h,nx) raw f32 payload.
# Runs on the compute pool while later bands are still fetching. The
# read affine (SourceNode scale/offset) is applied to the DN cube inside
# the kernel so it sees what a scaled read would have produced.
#' Daemon task body: reduce one band (or strip) under the shared mask.
#'
#' Reads a band cube plus the shared cleaned-mask cube, applies the
#' masked-apply function and reduces over time to a raw f32 payload.
#' Internal (exported only so mirai daemons can address it via `::`).
#'
#' @keywords internal
#' @export
.gd_compute_masked_band <- function(job, k) {
  .require_anvl()
  t0 <- proc.time()[["elapsed"]]
  dev <- .exec_device(k$dev)
  n <- length(job$band_bins)
  nx <- k$nx
  y0 <- if (is.null(job$rows)) 0L else job$rows[[1L]]
  h <- if (is.null(job$rows)) k$ny else job$rows[[2L]]
  strip <- h < k$ny
  read_rows <- function(f, base_rows = 0) {
    if (!strip && base_rows == 0) {
      return(readBin(f, "raw", n = h * nx * 4L))
    }
    con <- file(f, "rb")
    on.exit(close(con))
    seek(con, (base_rows + as.numeric(y0)) * nx * 4)
    readBin(con, "raw", n = h * nx * 4L)
  }
  cube <- function(bins) {
    g_upload_raw(
      do.call(c, lapply(bins, read_rows)),
      "f32",
      c(length(bins), h, nx),
      device = dev
    )
  }
  band <- cube(job$band_bins)
  masked <- length(k$mask_bin) == 1L
  created0 <- .gd_jit_stats$creates %||% 0L
  jf <- .gd_cached_jit(
    job$ck,
    .gd_lean_fn(k$F, k$op, k$nan_rm, job$affine, masked),
    dev
  )
  out <- if (masked) {
    mask_strip <- if (!strip) {
      g_upload_raw(
        readBin(k$mask_bin, "raw", n = n * k$ny * nx * 4L),
        "f32",
        c(n, h, nx),
        device = dev
      )
    } else {
      # one seek per slice into the whole-grid mask cube
      g_upload_raw(
        do.call(
          c,
          lapply(seq_len(n) - 1L, function(i) {
            read_rows(k$mask_bin, base_rows = as.numeric(i) * k$ny)
          })
        ),
        "f32",
        c(n, h, nx),
        device = dev
      )
    }
    g_download_raw(jf(list(band, mask_strip)))
  } else {
    g_download_raw(jf(list(band)))
  }
  attr(out, "gd_t") <- proc.time()[["elapsed"]] - t0
  attr(out, "gd_jit") <- (.gd_jit_stats$creates %||% 0L) - created0
  out
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
  nx <- k$nx
  ny <- k$ny
  buf <- rep(writeBin(NaN, raw(), size = 4L), nx * ny) # all-nodata default
  tw <- 0
  err <- tryCatch(
    {
      if (!length(j$locs)) {
        cli::cli_abort("no items for this slice")
      }
      # WARP-ON-READ (via the adapter): warp the slice's REMOTE items straight
      # into the f32 buffer in one gdalwarp -- GDAL reads (windowed vsicurl),
      # reprojects and mosaics the sources itself. No tmpfs GTiff fetch, no
      # per-slice local index. Ordered by datetime so overlap resolution (last
      # source wins) matches the GTI SORT_FIELD=datetime, highest-on-top path.
      tw <- system.time(
        buf <- .gdal_with_retry(
          function() {
            gdal_warp_to_buffer(
              buf,
              nx,
              ny,
              k$gtstr,
              k$wkt,
              j$locs[order(j$dt)],
              j$nodata,
              resampling = j$resampling %||% "near"
            )
          },
          what = "slice warp"
        )
      )[["elapsed"]]
      NA_character_
    },
    error = function(e) conditionMessage(e)
  )
  writeBin(buf, j$bin) # always write a complete slice (real or all-NaN)
  rm(buf)
  gc(FALSE)
  .garry_malloc_trim()
  list(err = err, tf = 0, tw = tw)
}
