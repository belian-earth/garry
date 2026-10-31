#' @include executor.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Daemon-side code: every function that executes IN a mirai daemon
# process, addressed cross-process via `garry::`: the .daemon_*
# family, the composite-direct task bodies, memory hygiene, and the
# ABI token that guards host/daemon namespace skew. Keeping every
# cross-process entry point in one file is what keeps the ABI
# enrollment honest (deep review 2026-08-02): a body added here is a
# body the skew check covers.
# ---------------------------------------------------------------------------

# This process's kernels by content key, filled through .daemon_kernel()
# alone: on a daemon, and on the host for its own kernels.
.daemon_cache <- new.env(parent = emptyenv())
# Kernels it holds before it empties. A compiled tail kernel keeps about
# 2.2 MB. Too few and a pool that revisits shapes recompiles on every
# pass: eight boxes at 14 kernels each took 36 s a pass at 64, 26 s here.
.kernel_cache_max <- 256L
# Kernels created in this process (tests + progress lines).
.kernel_stats <- new.env(parent = emptyenv())

# Get or create the kernel under content key `ck`. A JitFunction's
# dispatcher cache is keyed on input shapes alone, never the function, so
# a kernel built per task recompiles every time; one kept under a key
# for all it closes over shares one dispatcher across tasks and runs.
# `fn` is NULL for a key-only launch: the host sends the key alone for a
# kernel it knows this daemon holds, as the kernel costs MBs a task. A
# miss then asks the host to resend the task with it.
.daemon_kernel <- function(ck, fn, dev = NULL) {
  jf <- .daemon_cache[[ck]]
  if (!is.null(jf)) {
    return(jf)
  }
  if (is.null(fn)) {
    cli::cli_abort(
      "garry_jit_miss: stage closure not cached on this daemon",
      class = c("garry_jit_miss", "garry_error"),
      call = NULL
    )
  }
  if (length(.daemon_cache) >= .kernel_cache_max) {
    .exec_jit_clear()
  }
  jf <- .kernel_of(fn, device = dev)
  .daemon_cache[[ck]] <- jf
  .kernel_stats$creates <- (.kernel_stats$creates %||% 0L) + 1L
  jf
}

# Return freed heap pages to the OS (glibc malloc_trim(0); no-op
# elsewhere). The scan-retention spike (benchmarks/scan-retention-
# spike.R, 2026-08-01) measured a scan daemon standing at 904 MB of
# which 475 MB was trimmable glibc arena and 72 MB evictable jit
# handles: the "retained scan working set" that walls off wide scan
# pools is mostly memory nobody holds. Called after every compute/write
# task (µs-cheap) and by .daemon_hygiene.
.garry_malloc_trim <- function() {
  .Call("garry_malloc_trim", PACKAGE = "garry")
}

# Deferred per-task hygiene. A task body's transients are dead when it
# returns, but a full gc costs ~35 ms on a daemon (150 ms under a busy
# fleet) whatever it frees, and it was running after EVERY task: on a
# 2 M pixel band read that was two thirds of the task (issue #25's
# drain). Bodies report their transient bytes here instead; the
# gc + malloc_trim pass runs once `.daemon_gc_budget_mb` of them have
# accumulated, so big tasks (device buffers, chunk payloads) still
# clean up every time and small ones amortise.
#
# The pass is a minor collection: a task's transients are young, and a
# minor gc frees them in ~1 ms, where a full one walks every traced
# kernel in the jit cache (0.2 s on a daemon holding hutan's SI tail,
# a fifth of its busy time). A minor gc leaves what an automatic gc
# promoted mid-task, such as a big task's inputs held by device
# buffers, so the pass is full once `.daemon_gc_full_factor` x
# `.daemon_gc_budget_mb` of transients (512 MB) have passed since the
# last full one. That bounds what a daemon holds back; on the SI tail
# minor passes settled ~110 MB above the full-gc footprint.
.daemon_gc_state <- new.env(parent = emptyenv())
.daemon_gc_budget_mb <- 128
.daemon_gc_full_factor <- 4

.daemon_gc_after <- function(bytes) {
  budget <- .daemon_gc_budget_mb * 2^20
  acc <- (.daemon_gc_state$bytes %||% 0) + bytes
  if (acc < budget) {
    .daemon_gc_state$bytes <- acc
    return(invisible(FALSE))
  }
  .daemon_gc_state$bytes <- 0
  since <- (.daemon_gc_state$since_full %||% 0) + acc
  full <- since >= .daemon_gc_full_factor * budget
  .daemon_gc_state$since_full <- if (full) 0 else since
  gc(FALSE, full = full)
  .garry_malloc_trim()
  invisible(TRUE)
}

# Bytes a task transient holds: raw payloads by length, R vectors by
# element width, lists summed (device arrays count through the host
# payload they were uploaded from).
.payload_bytes <- function(x) {
  if (is.list(x)) {
    return(sum(vapply(x, .payload_bytes, numeric(1))))
  }
  if (is.raw(x)) {
    return(as.numeric(length(x)))
  }
  if (is.integer(x) || is.logical(x)) {
    return(4 * as.numeric(length(x)))
  }
  if (is.numeric(x)) {
    return(8 * as.numeric(length(x)))
  }
  0
}

#' Daemon task body: memory hygiene: trim arenas, optionally evict the
#' jit cache.
#'
#' `deep = TRUE` additionally clears the jit cache (forces recompiles:
#' ~1 s for map kernels, ~20 s for scans): reserve it for memory
#' pressure; the default trim-only pass costs microseconds and gives
#' back what glibc is hoarding. Every pass also closes cached Zarr
#' handles, whose decoded chunks no trim can return.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#' @param deep Also evict the jit cache?
#' @param trim Also collect and trim? About 10 ms a daemon, which a run
#'   that only reads has no need of.
#' @return `TRUE` if the trim ran (glibc), invisibly.
#' @keywords internal
.daemon_hygiene <- function(deep = FALSE, trim = TRUE) {
  if (isTRUE(deep)) {
    .exec_jit_clear()
  }
  .gdal_zarr_release()
  .daemon_jit_reset()
  if (!trim) {
    return(invisible(FALSE))
  }
  gc(FALSE)
  invisible(.garry_malloc_trim())
}

#' Daemon task body: start a run with a fresh jit cache on macOS.
#'
#' Reusing a daemon's cached JitFunction across RUNS stalls on macOS:
#' the same family as the host-cache slowdown gated in
#' `.host_kernel` (test-kernel-cache tripwire, run 33505350958)
#' and the fused-on-reader hang (test-compute-on-read). It surfaced on
#' the daemons once kernel signatures became stable across plans
#' (`.fn_identity`, 2026-09-07): the macOS check went from a 37 min
#' pass to a 90 min elapsed kill inside test-write-tif with 20 min of
#' CPU, i.e. waiting, and Linux/Windows timings were unchanged. Until
#' debugged on real hardware every run starts cold there; kernels are
#' still shared across a run's tasks and key-only launches still hit.
#' A no-op elsewhere.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#' @return `TRUE` if the cache was cleared, invisibly.
#' @keywords internal
.daemon_jit_reset <- function() {
  if (.kernels_outlive_runs()) {
    return(invisible(FALSE))
  }
  .exec_jit_clear()
  invisible(TRUE)
}

# Store layout ABI version: bump on any incompatible change to the raw
# payload byte layout, region naming, or shared-value envelope.
.garry_store_abi <- 4L # 2: sink-only integer payloads (g_quantize)
# 3: a task's kernel can be a program set
# 4: a program set holds its constants once, as raw bytes

# Every cross-process entry point must be in the token: the .daemon_*
# family by pattern, plus these, invoked on daemons through
# asNamespace("garry") under other names (deep review 2026-08-02: they
# escaped the hash, so .gd_daemon_prep's skew check passed under skew).
.garry_abi_extra <- c(
  ".cd_fetch_warp",
  ".exec_read_padded",
  ".gd_compute_mask",
  ".gd_compute_masked_band",
  ".gd_warm_pipeline",
  ".gdal_cache_cap",
  ".gdal_handle_cap",
  ".http_auth_apply"
)

#' Daemon-facing ABI token: a hash of every `.daemon_*` entry point's
#' formals plus the store layout version.
#'
#' Daemons resolve the `.daemon_*` bodies from their INSTALLED library while
#' a development host frequently runs a `load_all()` tree; a namespace
#' skew yields "unused argument" mirai errors at best and silent
#' semantic drift at worst (positional renames, new masking arguments).
#' `packageVersion()` cannot guard this (constant through development);
#' the formals can. Internal; daemons evaluate their own token through
#' `asNamespace("garry")`.
#'
#' @return A single hash string.
#' @keywords internal
.garry_abi_token <- function() {
  ns <- asNamespace("garry")
  nms <- sort(c(ls(ns, all.names = TRUE, pattern = "^\\.daemon_"), .garry_abi_extra))
  nms <- nms[vapply(nms, function(n) is.function(ns[[n]]), logical(1))]
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
  # Ask every pool at once: the first ask loads garry on a fresh daemon
  # (about a second), and serially that was 6 s of a first collect().
  asks <- lapply(profiles, function(p) {
    mirai::mirai(asNamespace("garry")$.garry_abi_token(), .compute = p)
  })
  for (i in seq_along(profiles)) {
    p <- profiles[[i]]
    d <- .await_task(asks[[i]], p)
    if (inherits(d, "miraiError")) {
      why <- .task_failure(d)
      cli::cli_abort(
        c(
          "the daemons of pool {.val {p}} could not load garry.",
          "x" = "{why}",
          "i" = "Check the garry they load, then restart the pools ({.fn garry_daemons})."
        ),
        class = c("garry_version_skew_error", "garry_error"),
        call = NULL
      )
    }
    if (!identical(d, host)) {
      .garry_error(
        paste0(
          "host/daemon ABI skew on pool '",
          p,
          "' (host ",
          host,
          ", daemon ",
          d,
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
# the host clears the run.
.daemon_shm <- new.env(parent = emptyenv())

#' Daemon task body: release all pinned shared-memory regions.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @return `NULL`, invisibly.
#' @keywords internal
.daemon_shm_clear <- function() {
  rm(list = ls(.daemon_shm, all.names = TRUE), envir = .daemon_shm)
  gc(FALSE)
  invisible(NULL)
}

#' Daemon task body: release named shared-memory regions.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param keys Registry keys to drop (missing keys are ignored).
#' @return `NULL`, invisibly.
#' @keywords internal
.daemon_shm_drop <- function(keys) {
  keys <- intersect(keys, ls(.daemon_shm, all.names = TRUE))
  if (length(keys) > 0L) {
    rm(list = keys, envir = .daemon_shm)
    gc(FALSE)
  }
  invisible(NULL)
}

# -- Worker-side task bodies (run on daemons) ---------------------------------

# Compute-on-read: apply a fused single-consumer stage kernel to the
# whole padded read window, once, on the daemon that read it. `fuse` is
# list(ck, fn, dtype, out_key, tiles, out_pad, out_dtype, grow, wq): jit
# cache key (content-addressed), kernel, upload dtype, export node key,
# row-tile count, the export's ring and dtype, and the edge growth and
# write quantization where they apply. Returns the kernel's single
# export (pad consumed: core-sized).
#
# Tiled execution (`tiles > 1`, pointwise chains only, decided by
# placement's .fuse_tiles): the window is uploaded once, the kernel
# runs on row slices of the device copy, and the slices' exports are
# concatenated on device. Activations then scale with the tile, not
# the window (a 256-wide MLP over a 1 Mpx window peaks ~2 GB per call;
# 4 tiles hold ~0.5 GB), so a reader fleet fits the in-flight byte
# budget several times over instead of serialising on it. At most two
# distinct tile heights occur, so the jit cache compiles twice.
#
# `fuse$grow` = c(rows, cols) grows an edge read window to the stage's
# modal window shape and crops the export back (.sv_grow), so every
# window runs the one kernel.
.apply_fuse <- function(m, fuse) {
  jf <- .daemon_kernel(fuse$ck, fuse$fn)
  if (!is.null(fuse$grow)) {
    m <- .sv_grow(m, fuse$grow, fuse$dtype)
  }
  up <- if (.sv_is(m)) {
    g_upload_raw(m, "f32", .sv_dim(m))
  } else {
    g_upload(m, fuse$dtype)
  }
  if (fuse$tiles > 1L) {
    out_dev <- .apply_fuse_tiled(jf, up, fuse$tiles)
    res <- NULL
  } else {
    res <- jf(list(up))
    out_dev <- res[[1L]]
  }
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
  # A quantized sink is only ever written, as raw digital numbers; any
  # other export is a store value, as a compute stage's is.
  out <- if (is.null(fuse$wq)) {
    .sv_download_exports(list(out_dev))[[1L]]
  } else {
    g_download_raw(out_dev)
  }
  if (!is.null(fuse$grow)) {
    out <- .sv_crop(out, fuse$grow)
  }
  # the caller's deferred pass (.daemon_gc_after) collects the device
  # buffers; a full gc here ran after every fused window
  rm(res, out_dev, up)
  out
}

# Run a jitted fused kernel over `tiles` row slices of a device window
# (.., y, x) and concatenate the exports along y. Row bounds split as
# evenly as integer rows allow (two distinct heights at most).
.apply_fuse_tiled <- function(jf, up, tiles) {
  sh <- .g_shape(up)
  nd <- length(sh)
  ny <- sh[[nd - 1L]]
  tiles <- max(1L, min(as.integer(tiles), ny))
  base <- ny %/% tiles
  extra <- ny %% tiles
  heights <- rep(base, tiles) + c(rep(1L, extra), rep(0L, tiles - extra))
  starts <- cumsum(c(1L, heights[-tiles]))
  parts <- vector("list", tiles)
  for (i in seq_len(tiles)) {
    tile <- .g_slice_axis(
      up,
      nd - 1L,
      starts[[i]],
      starts[[i]] + heights[[i]] - 1L
    )
    parts[[i]] <- jf(list(tile))[[1L]]
    rm(tile)
  }
  od <- length(.g_shape(parts[[1L]]))
  out <- .g_concat_axis(parts, od - 1L)
  rm(parts)
  out
}

#' Daemon task body: read one source window into shared memory.
#'
#' Coarse reads share their per-compute-chunk parts as elements of one
#' shared list: consumers extract their element zero-copy. (Consumer-side RANGE subsetting of a mapped
#' matrix would materialise the whole window per input, a large
#' transient allocation, so the split happens producer-side here too.)
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param ra Read arguments (as `.stage_read_args()`).
#' @param cg `ChunkGrid`; `core` the chunk row; `key` the node key;
#'   `reg_key` the daemon registry slot pinning the region.
#' @param parts NULL for chunk-aligned reads (the buffer is shared
#'   whole under `key`), else per-compute-chunk windows (`r0`/`c0`
#'   0-based offsets, `nr`/`nc` sizes, `elt` the element name).
#' @param fuse The fused kernel to run on the window, or NULL.
#' @param read_raw Read as a raw f32 payload?
#' @return The shared object (serialises as its region name).
#' @keywords internal
.daemon_run_source_shm <- function(
  ra,
  cg,
  core,
  key,
  reg_key,
  parts = NULL,
  fuse = NULL,
  read_raw = FALSE
) {
  m <- .exec_read_padded(ra, cg, core, out = if (read_raw) "raw_f32" else "matrix")
  # a fused read's window (and its device copy, counted through it) dies
  # with the task however small the export (a 145-band predict window is
  # ~150 MB for a ~1 MB export)
  win_bytes <- .payload_bytes(m)
  if (!is.null(fuse)) {
    m <- .apply_fuse(m, fuse)
    if (fuse$out_pad > 0L) {
      m <- .exec_mask_edge(m, fuse$out_pad, core, cg@grid@dims, fuse$out_dtype)
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
  # Deferred by transient size (.daemon_gc_after).
  bytes <- .payload_bytes(m) + .payload_bytes(val)
  if (!is.null(fuse)) {
    bytes <- bytes + win_bytes
  }
  rm(m, val)
  .daemon_gc_after(bytes)
  sh
}

# Writer-daemon open-output cache: path -> GDALRaster (update mode).
# Lives for the run; the host closes it with .daemon_write_close.
.daemon_ds <- new.env(parent = emptyenv())
.daemon_output <- function(path) {
  ds <- .daemon_ds[[path]]
  if (is.null(ds)) {
    ds <- gdal_open_update(path)
    .daemon_ds[[path]] <- ds
  }
  ds
}

#' Daemon task body: write one sink chunk window to an output file.
#'
#' The streamed-sink write, moved OFF the host dispatch thread: the
#' host creates the output (geometry, bands, nodata) and ships only
#' the mori region NAME plus window coordinates; this body maps the
#' region, extracts the chunk, materialises/converts it and runs the
#' GDAL write: so the multi-GB conversion transients (f64 scan sinks
#' cannot ride the raw f32 store) live in one lean process that is
#' reaped per task, not on the thread that launches and harvests every
#' other task. One writer daemon per session: GTiff is single-writer,
#' and daemon-persistent open handles amortise the opens.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param path Output file (already created by the host).
#' @param x_off,y_off Window offsets.
#' @param val Shared store value; `el` names the element for split
#'   coarse-read parts, else `skey` (the export node key) extracts.
#' @param skey,el Extraction keys.
#' @param pad,dtype,nodata,n_chunks As the host-side write path.
#' @return `TRUE`.
#' @keywords internal
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
  ds <- .daemon_output(path)
  ch <- if (is.null(el)) val[[skey]] else val[[el]]
  .exec_check_writable(ch, n_chunks)
  .exec_write_chunk(ds, x_off, y_off, ch, pad, dtype, nodata)
  bytes <- .payload_bytes(ch)
  rm(ch, val)
  .daemon_gc_after(bytes)
  TRUE
}

#' Daemon task body: read a chunk and prepare its band writes.
#'
#' The read half of the read-only route's streamed write, on the read
#' pool: reads the chunk as raw f32, turns each band plane into the
#' vector GDAL writes (nodata folded, the integer-output check made)
#' and shares the planes in one shared-memory region pinned under
#' `reg`. The writer daemon maps the region by name, so the payload
#' never passes through the host and the writer only writes. Integer
#' sources bound for an integer output read straight into their planes
#' (.read_int_planes()).
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param ra Read arguments (as `.stage_read_args()`).
#' @param cg,core Chunk grid and chunk row.
#' @param dtype,nodata Output dtype and sentinel.
#' @param reg Registry key pinning the region until the host drops it.
#' @return list(name, reg, nr, nc, mb): the region name and registry
#'   key, the window size and the region's size in MB.
#' @keywords internal
.daemon_read_for_write <- function(ra, cg, core, dtype, nodata, reg) {
  planes <- .read_int_planes(ra, cg, core, dtype, nodata)
  bytes <- 0
  d <- c(core$y_size, core$x_size)
  if (is.null(planes)) {
    v <- .exec_read_padded(ra, cg, core, out = "raw_f32")
    d <- .sv_dim(v)
    planes <- lapply(
      seq_len(if (length(d) == 3L) d[[1L]] else 1L),
      function(b) {
        .write_vec(v, dtype, nodata, b)$v
      }
    )
    bytes <- .payload_bytes(v)
    rm(v)
  }
  sh <- mori::share(planes)
  .daemon_shm[[reg]] <- sh
  bytes_shared <- .payload_bytes(planes)
  bytes <- bytes + bytes_shared
  rm(planes)
  .daemon_gc_after(bytes)
  list(
    name = mori::shared_name(sh),
    reg = reg,
    nr = d[[length(d) - 1L]],
    nc = d[[length(d)]],
    mb = bytes_shared / 2^20
  )
}

#' Daemon task body: write prepared band planes to an output.
#'
#' The write half of the read-only route's streamed write: maps the
#' planes `.daemon_read_for_write()` shared and writes plane `b` to band
#' `band0 + b` of the output the host created. Shares the writer's
#' open-handle cache with `.daemon_write_chunk`.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param path Output file (already created by the host).
#' @param x_off,y_off Window offsets.
#' @param w The read task's result: region name and window size.
#' @param band0 Bands before this chunk's first.
#' @return `TRUE`.
#' @keywords internal
.daemon_write_shared <- function(path, x_off, y_off, w, band0) {
  ds <- .daemon_output(path)
  planes <- mori::map_shared(w$name)
  for (b in seq_along(planes)) {
    .gdal_write(ds, as.integer(band0 + b), x_off, y_off, w$nc, w$nr, planes[[b]])
  }
  # a mapping pins its shared memory past the reader's drop until a
  # collection unmaps it
  bytes <- .payload_bytes(planes)
  rm(planes)
  .daemon_gc_after(bytes)
  TRUE
}

#' Daemon task body: close every output the writer holds open.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @return The close failures, named by output path (empty when all
#'   closed).
#' @keywords internal
.daemon_write_close <- function() {
  # all.names: the cache is keyed by OUTPUT PATH, and ls() hides
  # dot-prefixed names by default -- a "./out.tif" key (every cog=TRUE
  # temp under a relative path) was invisible here, so its dataset was
  # never closed and the file stayed an unflushed zero-filled shell
  # (diagnosed 2026-08-13: pools + relative path + cog wrote "all
  # zeros" while the data sat in the writer's block cache).
  ks <- ls(.daemon_ds, all.names = TRUE)
  failed <- character(0)
  for (p in ks) {
    why <- .gdal_close_failure(.daemon_ds[[p]], p)
    if (!is.null(why)) {
      failed[[p]] <- why
    }
  }
  rm(list = ks, envir = .daemon_ds)
  gc(FALSE)
  failed
}

#' Daemon task body: fetch one item-asset's target-window bytes to a
#' local file.
#'
#' The fetch half of the fetch/assemble split: a plain
#' `gdal_translate -srcwin` of the window intersecting the target
#' extent (plus a warp-kernel margin, `.fetch_margin`), remote COG to local tmpfs,
#' native dtype and blocks; no warp, no mosaic on the remote path.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param location Source path/URL.
#' @param out_file Local destination.
#' @param ext,crs Target extent and CRS defining the window.
#' @param target_res Target x resolution: a coarser grid decimates the
#'   fetch.
#' @return `TRUE`.
#' @keywords internal
.daemon_fetch_window <- function(
  location,
  out_file,
  ext,
  crs,
  target_res = NULL
) {
  .gdal_with_retry(
    function() {
      gdal_fetch_window(
        location,
        out_file,
        ext,
        crs,
        out_res = target_res
      )
    },
    what = "fetch",
    src = location
  )
  .garry_malloc_trim()
  TRUE
}

#' Daemon task body: run one jitted stage closure on shared-memory
#' inputs.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param cache_key Per-run jit cache key.
#' @param fn Stage kernel (a closure or a program set), NULL on a key-only
#'   launch; `in_vals`/`in_keys`/`trims`/`dtypes`
#'   describe the inputs (`in_keys` name the element to extract from
#'   each shared value: the node key, or a part name for coarse
#'   reads); `reg_key` the daemon registry slot for the result.
#'   `grow` = c(rows, cols) pads an edge chunk's inputs to the stage's
#'   modal chunk shape and crops the outputs back (see `.sv_grow()`).
#' @return The shared result (serialises as its region name).
#' @keywords internal
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
  edge = NULL,
  wq = NULL,
  grow = NULL
) {
  dev <- .exec_device(device)
  jf <- .daemon_kernel(cache_key, fn, dev)
  inputs <- Map(
    function(v, k, tr, dt) {
      .sv_upload(v[[k]], tr, dt, dev, grow = grow)
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
  res <- .sv_download_exports(dev_res)
  if (!is.null(grow)) {
    res <- .sv_crop(res, grow)
  }
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
        edge$gdims,
        edge$dtypes[[k]]
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
  # Deferred by transient size (.daemon_gc_after): the device inputs
  # count through the host payloads they were uploaded from.
  bytes <- .payload_bytes(res) +
    .payload_bytes(Map(function(v, k) v[[k]], in_vals, in_keys))
  rm(inputs, res)
  .daemon_gc_after(bytes)
  sh
}

#' Daemon task body: pre-compile stage closures for their modal chunk
#' shape.
#'
#' Runs on compute-pool daemons at run start (see `garry_daemons()`),
#' while the read pool owns the network drain: fills the per-daemon
#' jit cache, compiling a program's first shape or tracing a closure
#' through one dummy execution, so the XLA compile never lands on a
#' tail chunk.
#' Get-or-create against the same cache keys the real tasks use. A
#' failure raises: the host clears the kernel's warm mark, reports it,
#' and the kernel's first task compiles it.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @param specs List of per-stage specs: `ck` cache key, `fn` stage
#'   closure, `dtypes` per-input upload dtypes, `nr`/`nc` modal input
#'   dims.
#' @return `NULL`, invisibly.
#' @keywords internal
.daemon_warm_jit <- function(specs) {
  for (sp in specs) {
    dev <- .exec_device(sp$device)
    jf <- .daemon_kernel(sp$ck, sp$fn, dev)
    # a program's warm-up is its compile: nothing is left to trace
    if (!is.null(attr(jf, "warm"))) {
      attr(jf, "warm")()
      next
    }
    dummy <- Map(
      function(dt, ob) {
        if (ob > 1L) {
          g_upload(array(0, c(ob, sp$nr, sp$nc)), dt, device = dev)
        } else {
          g_upload(matrix(0, sp$nr, sp$nc), dt, device = dev)
        }
      },
      sp$dtypes,
      sp$outers
    )
    invisible(g_download(jf(unname(dummy))))
    rm(dummy)
  }
  gc(FALSE)
  invisible(NULL)
}

# -- composite-direct daemon task bodies --------------------------------------

#' Daemon task body: kernels created in this process so far.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#' @return Integer count.
#' @keywords internal
.daemon_jit_creates <- function() .kernel_stats$creates %||% 0L

# Rebuild the lean band kernel from a spec. Shared by the real task body
# and the warm-up so both produce semantically identical closures for one
# ck (the ck hashes exactly these ingredients: F, op, nan_rm, affine,
# masked, device). Forced for .gd_mask_fn()'s reason.
.gd_lean_fn <- function(F, op, nan_rm, affine, masked) {
  force(F)
  force(op)
  force(nan_rm)
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

# The mask kernel of a chain. A kernel outlives its task in the cache, so
# it is built here and not inline, with every argument forced: a closure
# holds the frame it was made in, and a promise the frame of its caller.
.gd_mask_fn <- function(chain, halo) {
  force(chain)
  force(halo)
  function(inp) .gd_replay_mask(inp[[1L]], chain, halo)
}

#' Daemon task body: pre-compile the pipeline lean kernels.
#'
#' Runs on each compute-pool daemon while the read pool owns the fetch
#' drain: get-or-create each spec's JitFunction under the same `ck` the
#' real band tasks use, then execute once per strip height on `g_fill`
#' dummies (the fill is represented in the program: no host bytes move)
#' so the XLA compile never lands on the post-fetch tail. A failure
#' raises: the host reports it, and a band task compiles the kernel.
#'
#' Internal; daemons reach it through `asNamespace("garry")`.
#' @param specs List of kernel specs: `ck`, `F`, `op`, `nan_rm`,
#'   `affine`, `masked`, `dev`, `n` slice count, `hs` strip heights, `nx`.
#' @return `NULL`, invisibly.
#' @keywords internal
.gd_warm_pipeline <- function(specs) {
  for (sp in specs) {
    dev <- .exec_device(sp$dev)
    jf <- .daemon_kernel(
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
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @keywords internal
.gd_compute_mask <- function(k) {
  dev <- .exec_device(k$dev)
  n <- length(k$fmask_bins)
  fm <- g_upload_raw(
    do.call(
      c,
      lapply(k$fmask_bins, function(f) readBin(f, "raw", n = as.numeric(k$ny) * k$nx * 4))
    ),
    "f32",
    c(n, k$ny, k$nx),
    device = dev
  )
  jf <- .daemon_kernel(k$ck, .gd_mask_fn(k$chain, k$halo), dev)
  r <- g_download_raw(jf(list(fm)))
  attributes(r) <- NULL
  writeBin(r, k$out_bin) # whole cube, row-major f32
  bytes <- 2 * .payload_bytes(r) # the fmask cube read, and the mask written
  rm(fm, r)
  .daemon_gc_after(bytes)
  invisible(TRUE)
}

# Pipeline daemon task: one band's median (whole grid, or one horizontal
# strip when `job$rows = c(y0, h)` is set: the bins are headerless
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
#' Internal; daemons reach it through `asNamespace("garry")`.
#'
#' @keywords internal
.gd_compute_masked_band <- function(job, k) {
  t0 <- proc.time()[["elapsed"]]
  dev <- .exec_device(k$dev)
  n <- length(job$band_bins)
  nx <- k$nx
  y0 <- if (is.null(job$rows)) 0L else job$rows[[1L]]
  h <- if (is.null(job$rows)) k$ny else job$rows[[2L]]
  strip <- h < k$ny
  read_rows <- function(f, base_rows = 0) {
    if (!strip && base_rows == 0) {
      return(readBin(f, "raw", n = as.numeric(h) * nx * 4))
    }
    con <- file(f, "rb")
    on.exit(close(con))
    seek(con, (base_rows + as.numeric(y0)) * nx * 4)
    readBin(con, "raw", n = as.numeric(h) * nx * 4)
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
  created0 <- .kernel_stats$creates %||% 0L
  jf <- .daemon_kernel(
    job$ck,
    .gd_lean_fn(k$F, k$op, k$nan_rm, job$affine, masked),
    dev
  )
  inputs <- list(band)
  if (masked) {
    inputs[[2L]] <- if (!strip) {
      g_upload_raw(
        readBin(k$mask_bin, "raw", n = as.numeric(n) * k$ny * nx * 4),
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
  }
  out <- g_download_raw(jf(inputs))
  attr(out, "gd_t") <- proc.time()[["elapsed"]] - t0
  attr(out, "gd_jit") <- (.kernel_stats$creates %||% 0L) - created0
  # the strip's cubes, read here and held on the device
  bytes <- length(inputs) * 4 * as.numeric(n) * h * nx
  rm(inputs, band)
  .daemon_gc_after(bytes)
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
#' Internal; daemons reach it through `asNamespace("garry")`.
#' @param j Per-slice job (locs/dt/nodata/resampling/bin).
#' @param k Grid-constant bundle (nx/ny/gtstr/wkt).
#' @return List with `tw` (warp seconds).
#' @keywords internal
.cd_fetch_warp <- function(j, k) {
  nx <- k$nx
  ny <- k$ny
  if (!length(j$locs)) {
    cli::cli_abort(
      c(
        "a warp-on-read slice has no items to read.",
        "i" = "Check the source's slice filter against its index."
      ),
      class = c("garry_read_error", "garry_error")
    )
  }
  buf <- rep(writeBin(NaN, raw(), size = 4L), nx * ny) # no source reaches: NaN
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
          resampling = j$resampling,
          band = j$band
        )
      },
      what = "slice warp",
      src = j$locs
    )
  )[["elapsed"]]
  writeBin(buf, j$bin)
  bytes <- .payload_bytes(buf)
  rm(buf)
  .daemon_gc_after(bytes)
  list(tw = tw)
}
