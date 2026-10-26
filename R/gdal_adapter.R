#' @include grid.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# The GDAL adapter: the ONLY file that speaks GDAL conventions (decision
# D13, grep-enforced by test-gdal-quarantine.R; the srs_*/transform_*
# helpers in grid.R/chunk_grid.R are the sanctioned exceptions).
#
# Conventions translated here and nowhere else:
# - GDAL row-major reads -> garry [row = y, col = x] matrices, north-up,
#   row 1 = northernmost (D13);
# - GDT_* names -> garry dtype strings;
# - file/user nodata -> NaN at read time (D8): downstream code never
#   sees a sentinel.
# ---------------------------------------------------------------------------

# GDAL data type name -> garry dtype.
.gdal_dtype_map <- c(
  Byte = "u8",
  Int8 = "i8",
  UInt16 = "u16",
  Int16 = "i16",
  UInt32 = "u32",
  Int32 = "i32",
  UInt64 = "u64",
  Int64 = "i64",
  Float32 = "f32",
  Float64 = "f64"
)

# Dataset handle cache: open once per (path, open options) per process,
# LRU-capped. An open dataset is not free: a GTI/warped mosaic pins
# warper buffers, VSICURL caches and block-cache pages, so a daemon
# that reads many distinct slices grows without bound if handles are
# never closed (measured: multi-GB per daemon, machine OOM). Eviction
# closes the least-recently-used handle; reopening is milliseconds.
.gdal_cache <- new.env(parent = emptyenv())
.gdal_cache$handles <- list() # named, insertion-ordered = LRU order
.gdal_cache$stamps <- list() # key -> .gdal_local_stamp() at open
.gdal_cache$zarr_bytes <- list() # key -> bytes read through a Zarr handle

# http(s) URLs need the /vsicurl prefix so GDAL reads via HTTP range requests --
# metadata (header/IFD) and windowed pixel reads only -- instead of downloading
# the whole file. A Zarr connection string (ZARR:"<store>":/array) gets the
# same treatment on its store. Idempotent: already-/vsicurl, /vsi*, GTI: and
# local paths pass through unchanged.
.gdal_href <- function(href) {
  if (grepl("^https?://", href)) {
    return(paste0("/vsicurl/", href))
  }
  sub('^ZARR:"(https?://)', 'ZARR:"/vsicurl/\\1', href)
}

# Is a path a remote (network-backed) GDAL source? Covers driver
# connection strings that wrap a remote store, e.g. ZARR:"/vsicurl/...".
.gdal_is_remote <- function(path) {
  grepl(
    '^/vsi(curl|s3|gs|az|swift)|^https?://|^[A-Za-z0-9_]+:"(/vsi(curl|s3|gs|az|swift)|https?://)',
    path
  )
}

# The extra (non-spatial) dimensions of a multidimensional array read
# through its classic view. GDAL exposes an N-D array (Zarr, and other
# multidim drivers) as one band per combination of its extra dims and
# tags each band DIM_<dim>_INDEX (0-based) plus DIM_<dim>_VALUE when the
# dim has a coordinate array. A data.frame with one row per file band
# (`band`) and `<dim>_index` / `<dim>_value` columns, its dim names in
# attr "dims"; NULL for an ordinary multi-band file.
.gdal_band_dims <- function(ds) {
  nb <- ds$getRasterCount()
  kv <- lapply(seq_len(nb), function(b) {
    m <- ds$getMetadata(b, "")
    m <- m[grepl("^DIM_.+_(INDEX|VALUE)=", m)]
    stats::setNames(sub("^[^=]*=", "", m), sub("=.*$", "", m))
  })
  keys <- unique(unlist(lapply(kv, names)))
  dims <- sub("^DIM_(.+)_INDEX$", "\\1", grep("_INDEX$", keys, value = TRUE))
  if (!length(dims)) {
    return(NULL)
  }
  out <- data.frame(band = seq_len(nb))
  for (d in dims) {
    ik <- paste0("DIM_", d, "_INDEX")
    vk <- paste0("DIM_", d, "_VALUE")
    out[[paste0(d, "_index")]] <- vapply(kv, function(x) as.integer(x[ik]), integer(1))
    out[[paste0(d, "_value")]] <- vapply(kv, function(x) unname(x[vk]), character(1))
  }
  if (anyNA(out[paste0(dims, "_index")])) {
    return(NULL)
  }
  attr(out, "dims") <- dims
  out
}

# Evaluate `code` with GDAL's error messages silenced (gdalraster's quiet
# handler); errors still reach R as conditions.
.gdal_quiet_errors <- function(code) {
  gdalraster::push_error_handler("quiet")
  on.exit(gdalraster::pop_error_handler(), add = TRUE)
  force(code)
}

# vsicurl allowlist entries (matched as filename suffixes) a Zarr store
# needs: v3 zarr.json and its extensionless chunk keys ({noext}), v2
# metadata keys, and v2 chunk keys such as 0.0.0 (ending in a digit). No
# GDAL sidecar probe (.aux.xml, .ovr, .msk, ...) ends in any of them.
.zarr_allowed_ext <- c(
  ".json", ".zarray", ".zgroup", ".zattrs", ".zmetadata", 0:9, "{noext}"
)

# Is a path a Zarr array (by connection string or store suffix)?
.gdal_is_zarr <- function(path) {
  grepl('^ZARR:|\\.zarr/?$', path, ignore.case = TRUE)
}

# Does opening `path` reach the network? A GTI index is a local file, but
# opening it opens its first tile to infer band count, type and nodata,
# so it is remote when its tiles are (read from the index sidecar; an
# index without one counts as local).
.gdal_opens_remote <- function(path) {
  if (.gdal_is_remote(path)) {
    return(TRUE)
  }
  if (!startsWith(path, "GTI:")) {
    return(FALSE)
  }
  meta_f <- paste0(sub("^GTI:", "", path), ".meta.rds")
  if (!file.exists(meta_f)) {
    return(FALSE)
  }
  any(.gdal_is_remote(readRDS(meta_f)$entries$location))
}

# Scope the remote-open hygiene config around a block, for garry's OWN
# host-side opens of REMOTE sources. Two savings, both measured on a
# 64-band AEF COG (2026-08-12): EMPTY_DIR suppresses the sidecar-probe
# storm (~25-30 sequential 404 round-trips: .IMD/.RPB/.PVL/_rpc.txt/
# .msk/.vat.dbf and case variants -- ~8 s at typical RTT, paid at the
# warp seam and the metadata probe), and the 4 MB ingest collapses the
# serial 16 KB IFD walk of a many-band header into one request
# (probe 7.5 s -> 1.0 s; first warp 8.5 s -> 0.01 s). Scoped, not
# global: the host's OWN config stays untouched outside garry calls,
# so user-level local reads keep sidecar semantics (the reason
# garry_daemons() never configures the host). Daemons already run
# EMPTY_DIR globally (garry_gdal_config); re-scoping there is a no-op.
#
# A Zarr store also scopes the vsicurl allowlist: the Zarr driver probes
# PAM sidecars (.aux.xml, .aux, .ovr) by name whatever EMPTY_DIR says,
# seven serial 404s (~5 s) per open measured on OlmoEarth 2026-10-22.
# Admitting only Zarr's own keys (.zarr_allowed_ext) refuses them.
.gdal_quiet_remote <- function(code, zarr = FALSE) {
  prev_rd <- gdalraster::get_config_option("GDAL_DISABLE_READDIR_ON_OPEN")
  prev_ib <- gdalraster::get_config_option("GDAL_INGESTED_BYTES_AT_OPEN")
  prev_ext <- gdalraster::get_config_option("CPL_VSIL_CURL_ALLOWED_EXTENSIONS")
  gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  gdalraster::set_config_option("GDAL_INGESTED_BYTES_AT_OPEN", "4194304")
  if (zarr && !nzchar(prev_ext)) {
    gdalraster::set_config_option(
      "CPL_VSIL_CURL_ALLOWED_EXTENSIONS",
      paste(.zarr_allowed_ext, collapse = ",")
    )
  }
  on.exit(
    {
      gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", prev_rd)
      gdalraster::set_config_option("GDAL_INGESTED_BYTES_AT_OPEN", prev_ib)
      gdalraster::set_config_option("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", prev_ext)
    },
    add = TRUE
  )
  force(code)
}

# Modification stamp of a local file (mtime and size), or NULL for a
# remote or virtual path. A cached handle whose file changed since it was
# opened would serve the old pixels from its block cache.
.gdal_local_stamp <- function(path) {
  p <- sub("^GTI:", "", path)
  if (.gdal_is_remote(p) || !file.exists(p)) {
    return(NULL)
  }
  info <- file.info(p, extra_cols = FALSE)
  c(as.numeric(info$mtime), as.numeric(info$size))
}

# Decode blocks on every core for the rest of the calling function:
# GDAL_NUM_THREADS is read when a GTiff is opened, so `paths`' cached
# handles are dropped on entry (they reopen threaded) and on exit (later
# reads reopen as configured). Only the calling host process is affected.
#
# Not for a read that touches a Zarr store. The threaded warper and Zarr
# shard reader report from GDAL worker threads (a missing shard comes back
# as "shard file too small"), and gdalraster's message handler then calls
# into R off the main thread, which aborts the session (seen 2026-10-22).
# Remote Zarr reads are bandwidth-bound, so the threads buy nothing.
.with_gdal_threads <- function(paths, envir = parent.frame()) {
  if (any(vapply(paths, .gdal_is_zarr, logical(1)))) {
    return(invisible(NULL))
  }
  prev <- gdalraster::get_config_option("GDAL_NUM_THREADS")
  gdalraster::set_config_option("GDAL_NUM_THREADS", "ALL_CPUS")
  for (p in paths) .gdal_handle_drop(p)
  withr::defer(
    {
      gdalraster::set_config_option("GDAL_NUM_THREADS", prev)
      for (p in paths) .gdal_handle_drop(p)
    },
    envir = envir
  )
  invisible(NULL)
}

# Close and forget every cached handle on `path`, whatever its open
# options (writers call this before replacing a file).
.gdal_handle_drop <- function(path) {
  path <- .gdal_href(path)
  keys <- names(.gdal_cache$handles) %||% character(0)
  hit <- keys[keys == path | startsWith(keys, paste0(path, "\x1f"))]
  for (k in hit) {
    try(.gdal_cache$handles[[k]]$close(), silent = TRUE)
    .gdal_cache$handles[[k]] <- NULL
    .gdal_cache$stamps[[k]] <- NULL
    .gdal_cache$zarr_bytes[[k]] <- NULL
  }
  invisible(NULL)
}

# GDAL's Zarr driver keeps every chunk a sharded array decodes for the
# life of the dataset handle (GDAL 3.13: the batched shard read fills a
# per-array cache nothing evicts), so a cached handle that reads window
# after window grows by the decoded bytes: ~100 MB per 1024^2 x 64-band
# Int8 window, measured on OlmoEarth 2026-10-22. Count what each Zarr
# handle reads and close it once the count passes garry.zarr_handle_mb;
# the next read reopens it (under a second, the store's metadata is
# cached by then).
.gdal_zarr_budget <- function(path, open_options, band, src_px) {
  key <- paste(c(.gdal_href(path), open_options), collapse = "\x1f")
  h <- .gdal_cache$handles[[key]]
  el <- if (is.null(h)) {
    1L
  } else {
    tryCatch(.gdal_dtype_bytes(h$getDataTypeName(band[[1L]])), error = function(e) 1L)
  }
  used <- (.gdal_cache$zarr_bytes[[key]] %||% 0) + src_px * length(band) * el
  if (used > garry_opt("zarr_handle_mb") * 2^20 && !is.null(h)) {
    .gdal_handle_drop(path)
    used <- src_px * length(band) * el
  }
  .gdal_cache$zarr_bytes[[key]] <- used
  invisible(NULL)
}

.gdal_handle <- function(path, open_options = character(0)) {
  path <- .gdal_href(path) # range-read remote COGs, never pull whole
  key <- paste(c(path, open_options), collapse = "\x1f")
  stamp <- .gdal_local_stamp(path)
  h <- .gdal_cache$handles[[key]]
  if (!is.null(h) && !identical(.gdal_cache$stamps[[key]], stamp)) {
    try(h$close(), silent = TRUE) # the file changed under the handle
    .gdal_cache$handles[[key]] <- NULL
    .gdal_cache$stamps[[key]] <- NULL
    .gdal_cache$zarr_bytes[[key]] <- NULL
    h <- NULL
  }
  if (!is.null(h)) {
    .gdal_cache$handles[[key]] <- NULL # move to MRU position
    .gdal_cache$handles[[key]] <- h
    return(h)
  }
  open_raw <- function() {
    if (length(open_options) > 0L) {
      methods::new(gdalraster::GDALRaster, path, TRUE, open_options)
    } else {
      methods::new(gdalraster::GDALRaster, path, read_only = TRUE)
    }
  }
  # Remote opens run under the scoped hygiene config (sidecar-probe
  # storm + serial IFD walk otherwise cost ~8 s each at typical RTT).
  open_ds <- function() {
    if (!.gdal_opens_remote(path)) {
      return(open_raw())
    }
    zarr <- .gdal_is_zarr(path)
    if (zarr) {
      # The Zarr driver's coordinate-array lookup walks above the store
      # (malformed /vsicurl URLs such as https://band/zarr.json) and
      # reports each miss as a GDAL warning or failure on an open that
      # succeeds. Open quietly; on failure open again so GDAL's own
      # messages say why.
      h <- tryCatch(
        .gdal_quiet_remote(.gdal_quiet_errors(open_raw()), zarr = TRUE),
        error = function(e) NULL
      )
      if (!is.null(h)) {
        return(h)
      }
    }
    .gdal_quiet_remote(open_raw(), zarr = zarr)
  }
  # A GTI mosaic pinned to the analysis grid reprojects mixed-UTM-zone tiles
  # (HLS spans several zones), so PROJ reports "several coordinate operations
  # ... artifacts may appear". The ambiguity is inherent to warping multi-zone
  # sources onto one grid and the divergence is sub-pixel; muffle just that
  # benign notice so it does not spam once per asset. Every other warning
  # surfaces.
  h <- withCallingHandlers(
    open_ds(),
    warning = function(w) {
      if (
        grepl(
          "Several coordinate operations",
          conditionMessage(w),
          fixed = TRUE
        )
      ) {
        invokeRestart("muffleWarning")
      }
    }
  )
  cap <- garry_opt("handle_cache_max")
  while (length(.gdal_cache$handles) >= cap) {
    k1 <- names(.gdal_cache$handles)[[1L]]
    try(.gdal_cache$handles[[1L]]$close(), silent = TRUE)
    .gdal_cache$handles[[1L]] <- NULL
    .gdal_cache$stamps[[k1]] <- NULL
    .gdal_cache$zarr_bytes[[k1]] <- NULL
  }
  .gdal_cache$handles[[key]] <- h
  .gdal_cache$stamps[[key]] <- stamp
  h
}

# Path-specific GDAL config (VSISetPathSpecificOption): options that
# apply only to files under `prefix`, e.g. credentials scoped to one
# provider (garry_http_auth()).
gdal_set_path_option <- function(prefix, key, value) {
  gdalraster::vsi_set_path_option(prefix, key, value)
  invisible(NULL)
}

gdal_clear_path_options <- function(prefix) {
  gdalraster::vsi_clear_path_options(prefix)
  invisible(NULL)
}

# A sourceless VRT on `grid`: GDAL reads every pixel inside it as 0, and
# garry's halo reads beyond it stay NaN, so it marks which cells of a
# padded chunk lie inside the grid at no read cost. Float32 so the halo
# can hold NaN. One file per grid per session.
.gdal_cache$blank <- list()
gdal_blank_vrt <- function(grid) {
  key <- paste(c(grid@crs, grid@transform, grid@dims), collapse = "\x1f")
  hit <- .gdal_cache$blank[[key]]
  if (!is.null(hit) && file.exists(hit)) {
    return(hit)
  }
  path <- tempfile("garry-grid-", fileext = ".vrt")
  ds <- gdalraster::create(
    "VRT",
    path,
    grid@dims[["x"]],
    grid@dims[["y"]],
    1L,
    "Float32",
    return_obj = TRUE
  )
  ds$setGeoTransform(grid@transform)
  ds$setProjection(grid@crs)
  ds$close()
  .gdal_cache$blank[[key]] <- path
  path
}

# Close every cached Zarr handle, freeing the decoded chunks GDAL holds
# for it. Daemons run this between runs: the chunks sit in GDAL's heap,
# which neither gc() nor malloc_trim returns, and garry's memory model
# does not count them.
.gdal_zarr_release <- function() {
  keys <- names(.gdal_cache$handles) %||% character(0)
  for (k in keys[.gdal_is_zarr(sub("\x1f.*$", "", keys))]) {
    try(.gdal_cache$handles[[k]]$close(), silent = TRUE)
    .gdal_cache$handles[[k]] <- NULL
    .gdal_cache$stamps[[k]] <- NULL
    .gdal_cache$zarr_bytes[[k]] <- NULL
  }
  invisible(NULL)
}

.gdal_handle_reset <- function() {
  for (h in .gdal_cache$handles) {
    try(h$close(), silent = TRUE)
  }
  .gdal_cache$handles <- list()
  .gdal_cache$stamps <- list()
  .gdal_cache$zarr_bytes <- list()
}

#' Inspect a GDAL source and build its GridSpec (plus read metadata).
#'
#' @param path Path or VSI URL readable by GDAL.
#' @param band 1-based band index.
#' @param open_options GDAL open options ("KEY=VALUE").
#' @return A list: `grid` (`GridSpec`), `nodata` (length 0 or 1),
#'   `block_dim` (integer length 2, x then y), and `scale`/`offset`
#'   (each length 0 when the band carries no scaling metadata).
#' @export
gdal_grid_spec <- function(path, band = 1L, open_options = character(0)) {
  ds <- .gdal_handle(path, open_options)
  gt <- ds$getGeoTransform()
  nx <- ds$getRasterXSize()
  ny <- ds$getRasterYSize()

  dtype_name <- ds$getDataTypeName(band)
  dtype <- .gdal_dtype_map[[dtype_name]]
  if (is.null(dtype)) {
    cli::cli_abort("unsupported GDAL data type: {.val {dtype_name}}")
  }

  nodata <- ds$getNoDataValue(band)
  nodata <- if (is.na(nodata)) numeric(0) else as.numeric(nodata)

  # Band scale/offset (TIFF/GDAL metadata; DN -> physical is v*scale+offset).
  # Unset reads back as NA or as the identity (1, 0); both mean absent.
  sc <- ds$getScale(band)
  of <- ds$getOffset(band)
  sc <- if (is.na(sc)) 1 else as.numeric(sc)
  of <- if (is.na(of)) 0 else as.numeric(of)
  if (sc == 1 && of == 0) {
    sc <- numeric(0)
    of <- numeric(0)
  }

  block <- as.integer(ds$getBlockSize(band)) # (x, y)

  # Normalise to garry's north-up convention (D13). Most rasters are north-up
  # (gt[6] < 0), but some COGs (e.g. AEF embeddings) carry a positive y pixel
  # size (south-up); the footprint is identical, so take the corner min/max for
  # the extent and rebuild a north-up transform. Axis-aligned only: a rotated
  # geotransform cannot be an analysis grid.
  if (gt[3L] != 0 || gt[5L] != 0) {
    cli::cli_abort(
      "{.fn gdal_grid_spec}: rotated geotransform is not a valid analysis grid."
    )
  }
  x1 <- gt[1L] + nx * gt[2L]
  y1 <- gt[4L] + ny * gt[6L]
  xmin <- min(gt[1L], x1)
  xmax <- max(gt[1L], x1)
  ymin <- min(gt[4L], y1)
  ymax <- max(gt[4L], y1)

  grid <- GridSpec(
    crs = ds$getProjection(),
    transform = c(xmin, abs(gt[2L]), 0, ymax, 0, -abs(gt[6L])),
    extent = c(xmin, ymin, xmax, ymax),
    dims = c(x = nx, y = ny),
    dtype = dtype
  )
  list(grid = grid, nodata = nodata, block_dim = block, scale = sc, offset = of)
}

# -- Warper bypass: aligned decimating reads -----------------------------------

# garry resampling name -> GDAL RasterIO algorithm. Anything absent here
# has no RasterIO equivalent and keeps the warper.
.rio_resamp_names <- c(
  near = "NEAREST",
  nearest = "NEAREST",
  bilinear = "BILINEAR",
  cubic = "CUBIC",
  cubicspline = "CUBICSPLINE",
  lanczos = "LANCZOS",
  average = "AVERAGE",
  mode = "MODE",
  rms = "RMS"
)

# Round-trip tolerance in PIXEL units when testing grid alignment. At a
# 30 m pixel this is 3e-5 m: tight enough that only genuinely aligned
# grids pass, and a false negative merely keeps the warper.
.rio_align_tol <- 1e-6

.rio_near_int <- function(v) abs(v - round(v)) < .rio_align_tol

#' Can this warp be served by a plain decimating RasterIO read?
#'
#' A `WarpNode` whose target grid shares the source CRS, is axis-aligned,
#' starts on a source pixel boundary and has a whole-number pixel size
#' needs no warping at all: GDAL's RasterIO reads the window and
#' resamples it in one pass, which is measurably cheaper than building a
#' warped VRT and reading through the warper (2.6x on a 4-band Landsat
#' crop+3x-average, 0.98s -> 0.375s). Results are identical, including
#' overview selection and nodata handling at fill boundaries, because
#' both paths hand the same request to the same GDAL resampler.
#'
#' A target CRS that differs from the source's only by its false origin
#' (UTM north and south of one zone: a store in 326NN read onto a
#' southern 327NN grid) is the source CRS shifted by a constant, so the
#' target maps onto a window of the source just the same. The warper
#' reprojects every pixel there to reach the same cells; a nearest-
#' neighbour read of a 128-band OlmoEarth Zarr window took 8x longer
#' through it. Such a target takes the fast path for nearest-neighbour
#' reads only, the one read that matches the warper on every GDAL version.
#'
#' Integer bands are the one exception to that identity: an
#' interpolating resampler produces fractional values that each engine
#' rounds back to the band type itself, and under GDAL 3.13.1 on ARM
#' (new NEON float->int conversion paths) RasterIO and the warper round
#' .5 ties in opposite directions -- every tie came back +1 DN through
#' the fast path on the macOS CI runners. Identity is the contract, so
#' integer bands take the fast path only for NEAREST, where no rounding
#' happens.
#'
#' A south-up source (positive y pixel size: every AEF tile) stores its
#' rows from the south. A target on its own pixels is still a window of
#' it, read with its rows reversed (`flip`), the read
#' [gdal_read_window()] gives any south-up file; a decimating target
#' keeps the warper.
#'
#' Returns `NULL` (keep the warper) unless every condition holds, so the
#' warper stays the default and this is a pure opt-in fast path.
#'
#' @param src_path Source path or VSI URL.
#' @param target_grid The `WarpNode` target [GridSpec()].
#' @param resampling Requested resampling name.
#' @param open_options Source open options; any at all keep the warper
#'   (GTI and other option-driven sources are left alone in v1).
#' @param band 1-based band index (or indices) the read will use. Their
#'   data types drive the integer gate above.
#' @param nodata The source node's sentinel (length 0 or 1). Averaging
#'   declines unless the file declares the same value.
#' @param partial `TRUE` for one source of several
#'   ([.rio_direct_multi_spec()]): the target may reach beyond the source,
#'   and only a nearest-neighbour read on the source's own pixels, with
#'   the file's nodata (if any) the node's, qualifies.
#' @return `NULL`, or a list with `fx`, `fy`, `x_off`, `y_off` (the
#'   target origin in source pixels, rows counted from the north),
#'   `resamp`, `flip`, and the source's `nx` and `ny`.
#' @keywords internal
.rio_direct_spec <- function(
  src_path,
  target_grid,
  resampling,
  open_options = character(0),
  band = 1L,
  nodata = numeric(0),
  partial = FALSE
) {
  if (length(src_path) != 1L || length(open_options) > 0L || !length(band)) {
    return(NULL)
  }
  resamp <- unname(.rio_resamp_names[resampling])
  if (length(resamp) != 1L || is.na(resamp)) {
    return(NULL)
  }

  if (partial && resamp != "NEAREST") {
    return(NULL)
  }
  ds <- tryCatch(.gdal_handle(src_path), error = function(e) NULL)
  if (is.null(ds)) {
    return(NULL)
  }
  if (partial && length(nodata) == 1L) {
    # the warper takes the node's sentinel for every source; a file whose
    # own differs would mask cells the warper keeps
    for (b in band) {
      file_nd <- tryCatch(ds$getNoDataValue(b), error = function(e) NA)
      if (
        !is.na(file_nd) && !identical(as.numeric(file_nd), as.numeric(nodata))
      ) {
        return(NULL)
      }
    }
  }
  if (resamp != "NEAREST") {
    for (b in band) {
      dtn <- tryCatch(ds$getDataTypeName(b), error = function(e) NULL)
      if (is.null(dtn) || !startsWith(dtn, "Float")) {
        return(NULL)
      }
      # RasterIO averaging skips only the file's own nodata; a sentinel the
      # node declares otherwise would be blended in, so leave it to the warper.
      if (length(nodata) == 1L) {
        file_nd <- tryCatch(ds$getNoDataValue(b), error = function(e) NA)
        if (!isTRUE(identical(as.numeric(file_nd), as.numeric(nodata)))) {
          return(NULL)
        }
      }
    }
  }
  gt <- tryCatch(ds$getGeoTransform(), error = function(e) NULL)
  if (length(gt) != 6L || anyNA(gt)) {
    return(NULL)
  }
  # Axis-aligned only: a rotated source cannot be expressed as a window.
  # A south-up one is read from its northern edge with its rows reversed.
  if (gt[[3L]] != 0 || gt[[5L]] != 0 || gt[[2L]] <= 0 || gt[[6L]] == 0) {
    return(NULL)
  }
  flip <- gt[[6L]] > 0
  res_y <- abs(gt[[6L]])
  north <- if (flip) gt[[4L]] + ds$getRasterYSize() * res_y else gt[[4L]]
  # A CRS that differs only by its false origin is the source's shifted:
  # the target's origin moves into source coordinates and the rest holds
  shift <- .crs_false_origin_shift(ds$getProjectionRef(), target_grid@crs)
  if (is.null(shift)) {
    return(NULL)
  }

  tt <- target_grid@transform
  if (tt[[3L]] != 0 || tt[[5L]] != 0 || tt[[6L]] >= 0) {
    return(NULL)
  }
  fx <- tt[[2L]] / gt[[2L]]
  fy <- -tt[[6L]] / res_y
  x_off <- (tt[[1L]] - shift[[1L]] - gt[[1L]]) / gt[[2L]]
  y_off <- (north - (tt[[4L]] - shift[[2L]])) / res_y
  if (!all(vapply(list(fx, fy, x_off, y_off), .rio_near_int, TRUE))) {
    return(NULL)
  }
  fx <- round(fx)
  fy <- round(fy)
  x_off <- round(x_off)
  y_off <- round(y_off)
  if (fx < 1 || fy < 1) {
    return(NULL)
  }
  # A flipped read, and one source's share of a mosaic, take the target
  # on the source's own pixels only.
  if ((flip || partial) && (fx != 1 || fy != 1)) {
    return(NULL)
  }
  # Through a shifted CRS, take only nearest-neighbour reads: the warper's
  # interpolating reads there depend on the GDAL version (3.13 returns the
  # source cells at a whole-pixel shift, 3.11 does not), so nearest
  # neighbour is the one read that matches it everywhere.
  if (any(shift != 0) && resamp != "NEAREST") {
    return(NULL)
  }
  # The target must lie wholly inside the source: the warper pads beyond
  # the edge with nodata, a windowed read cannot. One source of several
  # covers only its share (gdal_read_window_multi()).
  if (
    !partial &&
      (x_off < 0 ||
        y_off < 0 ||
        x_off + target_grid@dims[["x"]] * fx > ds$getRasterXSize() ||
        y_off + target_grid@dims[["y"]] * fy > ds$getRasterYSize())
  ) {
    return(NULL)
  }

  list(
    fx = as.integer(fx),
    fy = as.integer(fy),
    x_off = as.integer(x_off),
    y_off = as.integer(y_off),
    resamp = resamp,
    flip = flip,
    nx = as.integer(ds$getRasterXSize()),
    ny = as.integer(ds$getRasterYSize())
  )
}

#' Can a multi-path warp be served by direct reads of its sources?
#'
#' Tiles no mosaic VRT can hold (south-up AEF tiles) stay a multi-path
#' source that the warper reads together, every source warped into each
#' window. When each source lies on the target's own pixels in a CRS
#' the target shares (or shifts, see [.rio_direct_spec()]), a
#' nearest-neighbour read needs none of that: each source's share of a
#' window is a window of it ([gdal_read_window_multi()]). Every source
#' must qualify, or the warper reads them all.
#'
#' @inheritParams .rio_direct_spec
#' @param paths The source paths, in mosaic order.
#' @return `NULL`, or a list with `fx = fy = 1`, `resamp` and `srcs`, one
#'   [.rio_direct_spec()] result a source.
#' @keywords internal
.rio_direct_multi_spec <- function(
  paths,
  target_grid,
  resampling,
  band = 1L,
  nodata = numeric(0)
) {
  srcs <- lapply(paths, function(p) {
    .rio_direct_spec(
      p,
      target_grid,
      resampling,
      band = band,
      nodata = nodata,
      partial = TRUE
    )
  })
  if (!length(srcs) || any(vapply(srcs, is.null, logical(1)))) {
    return(NULL)
  }
  list(fx = 1L, fy = 1L, resamp = "NEAREST", srcs = srcs)
}

# Shared tail of a window read: nodata sentinel -> NaN, band affine, and
# the requested output form. Single-band and decimating reads both end
# here so the two cannot drift apart.
.gdal_finish_vec <- function(v, y_size, x_size, nodata, scale, offset, out) {
  # GDAL's buffer is already row-major: the raw f32 store payload (D19)
  # packs it in one C pass (sentinel, NA, affine, f32 cast), skipping
  # the numeric copy, the mask passes and the byrow transpose below.
  if (out == "raw_f32") {
    return(structure(
      .Call(
        "garry_finish_f32",
        v,
        as.numeric(nodata),
        as.numeric(scale),
        as.numeric(offset),
        PACKAGE = "garry"
      ),
      gdim = c(y_size, x_size),
      gdt = "f32"
    ))
  }
  # The same steps in doubles (sentinel and GDAL-masked NA -> NaN,
  # affine), transposed into the [y, x] matrix in one C pass.
  .Call(
    "garry_finish_matrix",
    v,
    as.numeric(y_size),
    as.numeric(x_size),
    as.numeric(nodata),
    as.numeric(scale),
    as.numeric(offset),
    PACKAGE = "garry"
  )
}

# A whole band read at a reduced size in one RasterIO call (GDAL picks
# overviews where the file has them), in garry's row order, nodata as NaN.
# The preview path: nothing beyond the requested size is read.
.gdal_read_resampled <- function(path, band, out_nx, out_ny, nodata = numeric(0)) {
  ds <- .gdal_handle(path)
  nx <- ds$getRasterXSize()
  ny <- ds$getRasterYSize()
  v <- ds$read(band, 0L, 0L, nx, ny, out_nx, out_ny)
  if (ds$getGeoTransform()[[6L]] > 0) {
    # south-up: rows to north-first
    v <- .Call(
      "garry_flip_rows",
      v,
      as.numeric(out_ny),
      as.numeric(out_nx),
      PACKAGE = "garry"
    )
  }
  .gdal_finish_vec(v, out_ny, out_nx, nodata, numeric(0), numeric(0), "matrix")
}

# Read a window of `rows` rows in garry's row order (row 1 = north,
# decision D13). gdal_grid_spec() presents a south-up file (positive y
# pixel size, e.g. AEF embedding COGs) as a north-up grid with the same
# footprint, so its rows are read from the mirrored offset and reversed.
.gdal_read_rows <- function(ds, band, x_off, y_off, x_size, rows) {
  gt <- ds$getGeoTransform()
  if (!(gt[[6L]] > 0)) {
    return(ds$read(band, x_off, y_off, x_size, rows, x_size, rows))
  }
  y_file <- ds$getRasterYSize() - y_off - rows
  v <- ds$read(band, x_off, y_file, x_size, rows, x_size, rows)
  .Call(
    "garry_flip_rows",
    v,
    as.numeric(rows),
    as.numeric(x_size),
    PACKAGE = "garry"
  )
}


#' Read a window from a GDAL source as a garry-oriented matrix.
#'
#' Returns the window with row 1 = northernmost. Offsets are 0-based
#' pixel coordinates. If `nodata` is supplied, matching cells (and any
#' file-level NA) are rewritten to NaN and the result is numeric.
#'
#' @param path Path or VSI URL readable by GDAL.
#' @param band 1-based band index, or a vector of them for a multi-band
#'   read in one pass.
#' @param x_off,y_off,x_size,y_size 0-based pixel window.
#' @param nodata Length-0 or length-1 sentinel to promote to NaN.
#' @param open_options GDAL open options ("KEY=VALUE").
#' @param out Output form: `"matrix"` (default) returns an R numeric
#'   result; `"raw_f32"` returns the pixels packed as a raw row-major
#'   f32 payload, avoiding a numeric copy when the result feeds a
#'   binary store or another process.
#' @param scale,offset Length-0 (absent) or length-1 band affine: values
#'   become `v * scale + offset` after the nodata sentinel is promoted
#'   to NaN, so sentinels never scale.
#' @param decim Optional decimating-read spec from [.rio_direct_spec()]
#'   (`fx`/`fy` integer decimation factors, `x_off`/`y_off` the source
#'   pixel origin of the target grid, `resamp` the RasterIO algorithm).
#'   When supplied the window arguments are read as TARGET-grid pixels
#'   and translated to the source window internally, so a caller chunked
#'   on the target grid needs no coordinate maths of its own.
#' @return With `out = "matrix"`: a numeric `y_size x x_size` matrix for
#'   a single band, or a `(band, y, x)` numeric array when `band` is a
#'   vector. With `out = "raw_f32"`: a raw row-major f32 payload (band
#'   planes contiguous when `band` is a vector).
gdal_read_window <- function(
  path,
  band,
  x_off,
  y_off,
  x_size,
  y_size,
  nodata = numeric(0),
  open_options = character(0),
  out = c("matrix", "raw_f32"),
  scale = numeric(0),
  offset = numeric(0),
  decim = NULL
) {
  out <- rlang::arg_match(out)
  # a scale alone means no offset (v * scale + numeric(0) is numeric(0))
  if (length(scale) == 1L && length(offset) == 0L) {
    offset <- 0
  }
  # A flipped direct read (a south-up source, see .rio_direct_spec()) is
  # the plain window read at the target's offset, which reverses its rows.
  if (isTRUE(decim$flip)) {
    x_off <- x_off + decim$x_off
    y_off <- y_off + decim$y_off
    decim <- NULL
  }
  if (.gdal_is_zarr(path)) {
    .gdal_zarr_budget(
      path,
      open_options,
      band,
      as.numeric(x_size) * y_size * (decim$fx %||% 1L) * (decim$fy %||% 1L)
    )
  }
  # Warper bypass (see .rio_direct_spec()): the window arrives in TARGET
  # pixels; translate it to the source window and let RasterIO resample
  # in the same pass as the read. Takes precedence over the raw-BSQ path
  # below, which cannot decimate.
  if (!is.null(decim)) {
    ds <- .gdal_handle(path, open_options)
    sx <- decim$x_off + x_off * decim$fx
    sy <- decim$y_off + y_off * decim$fy
    sw <- x_size * decim$fx
    sh <- y_size * decim$fy
    if (decim$fx > 1L || decim$fy > 1L) {
      prev <- gdalraster::get_config_option("GDAL_RASTERIO_RESAMPLING")
      gdalraster::set_config_option("GDAL_RASTERIO_RESAMPLING", decim$resamp)
      on.exit(
        gdalraster::set_config_option("GDAL_RASTERIO_RESAMPLING", prev),
        add = TRUE
      )
    }
    if (length(band) > 1L) {
      return(.gdal_read_window_bands(
        ds,
        band,
        x_off,
        y_off,
        x_size,
        y_size,
        nodata,
        out,
        scale,
        offset,
        decim = decim
      ))
    }
    return(.gdal_finish_vec(
      ds$read(band, sx, sy, sw, sh, x_size, y_size),
      y_size,
      x_size,
      nodata,
      scale,
      offset,
      out
    ))
  }
  # Raw-BSQ cube fast path: a garry raw cube (.bin + sibling
  # VRTRawRasterBand .vrt) reads via seek+readBin, skipping GDAL's
  # tile machinery AND this function's band-walk — measured 2026-08-02:
  # a 482 MB 73-band cube costs ~2.2 s through the GDAL path REGARDLESS
  # of compression (ZSTD == uncompressed == VRT-raw; the tile walk is
  # the cost, not the codec) vs 0.24 s raw. Anything non-conforming
  # (foreign VRTs, open options, out-of-range bands) falls through.
  if (length(open_options) == 0L) {
    info <- .raw_vrt_info(path)
    if (!is.null(info) && all(band >= 1L) && all(band <= info$nb)) {
      return(.raw_vrt_read(
        info,
        band,
        x_off,
        y_off,
        x_size,
        y_size,
        nodata,
        out,
        scale,
        offset
      ))
    }
  }
  ds <- .gdal_handle(path, open_options)
  if (length(band) > 1L) {
    return(.gdal_read_window_bands(
      ds,
      band,
      x_off,
      y_off,
      x_size,
      y_size,
      nodata,
      out,
      scale,
      offset
    ))
  }
  .gdal_finish_vec(
    .gdal_read_rows(ds, band, x_off, y_off, x_size, y_size),
    y_size,
    x_size,
    nodata,
    scale,
    offset,
    out
  )
}

# Rows a multi-band read takes per slab: as many as keep half the GDAL
# block cache holding one image row of every band (strips span the full
# raster width whatever the window; tiles at least the window's
# columns), in whole block rows. A decimating read (see
# .rio_direct_spec()) maps target rows to source rows by a factor, so
# each band reads its whole window in one call.
.gdal_band_slab <- function(ds, band, x_size, y_size, decim = NULL) {
  if (!is.null(decim)) {
    return(y_size)
  }
  bs <- as.integer(ds$getBlockSize(band[[1L]])) # (x, y)
  el_b <- tryCatch(
    .gdal_dtype_bytes(ds$getDataTypeName(band[[1L]])),
    error = function(e) 8L
  )
  row_b <- max(bs[[1L]], x_size) * length(band) * el_b
  cache_b <- garry_opt("gdal_cachemax_mb") * 2^20
  by <- max(1L, bs[[2L]])
  slab <- max(by, as.integer(floor(cache_b * 0.5 / row_b) %/% by) * by)
  min(slab, y_size)
}

# Source band types f32 holds exactly: their values reach an integer
# output unchanged whether read as integers or through the f32 payload.
.gdal_exact_int_types <- c("Byte", "Int8", "UInt16", "Int16")

# Read a window's bands as the integer planes an integer output writes
# (row-major, one per band, as gdal_write_window() hands them to GDAL),
# with no f32 payload between: an Int8 embedding store copied to an i8
# file spent more time building and unpacking the f32 cube than
# reading. Cells GDAL masks as nodata, or equal to the source node's
# `nodata`, become `out_nodata`, as the f32 route makes them NaN and
# its write folds NaN to the sentinel. Row slabs as
# .gdal_read_window_bands(). NULL, for the f32 route to take over, when
# a band is not an exact integer type, the source is a raw-BSQ cube, or
# a nodata cell meets no `out_nodata` (the f32 route raises that).
gdal_read_int_planes <- function(
  path,
  band,
  x_off,
  y_off,
  x_size,
  y_size,
  nodata = numeric(0),
  out_nodata = numeric(0),
  open_options = character(0),
  decim = NULL
) {
  if (length(open_options) == 0L && !is.null(.raw_vrt_info(path))) {
    return(NULL)
  }
  if (isTRUE(decim$flip)) {
    # as gdal_read_window(): a plain window read, rows reversed
    x_off <- x_off + decim$x_off
    y_off <- y_off + decim$y_off
    decim <- NULL
  }
  fx <- decim$fx %||% 1L
  fy <- decim$fy %||% 1L
  if ((fx > 1L || fy > 1L) && !identical(decim$resamp, "NEAREST")) {
    return(NULL)
  }
  if (.gdal_is_zarr(path)) {
    .gdal_zarr_budget(
      path,
      open_options,
      band,
      as.numeric(x_size) * y_size * fx * fy
    )
  }
  ds <- .gdal_handle(path, open_options)
  types <- vapply(band, function(b) ds$getDataTypeName(b), character(1))
  if (!all(types %in% .gdal_exact_int_types)) {
    return(NULL)
  }
  slab <- .gdal_band_slab(ds, band, x_size, y_size, decim)
  n_px <- as.numeric(y_size) * x_size
  planes <- lapply(band, function(b) integer(n_px))
  bare <- FALSE
  r0 <- 0L
  while (r0 < y_size) {
    rows <- min(slab, y_size - r0)
    for (k in seq_along(band)) {
      v <- if (is.null(decim)) {
        .gdal_read_rows(ds, band[[k]], x_off, y_off + r0, x_size, rows)
      } else {
        ds$read(
          band[[k]],
          decim$x_off + x_off * fx,
          decim$y_off + y_off * fy,
          x_size * fx,
          y_size * fy,
          x_size,
          y_size
        )
      }
      if (!is.integer(v)) {
        return(NULL)
      }
      hit <- .Call(
        "garry_fold_int_into",
        planes[[k]],
        as.numeric(r0) * x_size,
        v,
        as.numeric(nodata),
        as.numeric(out_nodata),
        PACKAGE = "garry"
      )
      bare <- bare || hit
    }
    r0 <- r0 + rows
  }
  if (bare) NULL else planes
}

# Multi-band window read: every band of the window in ONE pass, as a
# (band, y, x) cube (matrix out) or a rank-3 row-major raw f32 payload
# (band planes contiguous). Bands are read together inside row SLABS
# sized to the GDAL block cache: on interleaved files every native
# strip/tile holds all bands, so reading band-by-band over a window
# larger than the cache re-decompresses each block once per band as
# the cache evicts (measured 31x on a 72-band 1-row-strip DEFLATE
# file); slab-sized reads keep a slab's blocks resident across the
# band loop, so each block decompresses once regardless of cache size.
.gdal_read_window_bands <- function(
  ds,
  band,
  x_off,
  y_off,
  x_size,
  y_size,
  nodata,
  out,
  scale = numeric(0),
  offset = numeric(0),
  decim = NULL
) {
  nb <- length(band)
  slab <- .gdal_band_slab(ds, band, x_size, y_size, decim)
  n_px <- as.numeric(y_size) * x_size
  res <- if (out == "raw_f32") {
    raw(4 * nb * n_px)
  } else {
    array(NA_real_, c(nb, y_size, x_size))
  }
  r0 <- 0L
  while (r0 < y_size) {
    rows <- min(slab, y_size - r0)
    for (k in seq_len(nb)) {
      v <- if (is.null(decim)) {
        .gdal_read_rows(ds, band[[k]], x_off, y_off + r0, x_size, rows)
      } else {
        ds$read(
          band[[k]],
          decim$x_off + x_off * decim$fx,
          decim$y_off + y_off * decim$fy,
          x_size * decim$fx,
          y_size * decim$fy,
          x_size,
          y_size
        )
      }
      if (out == "raw_f32") {
        # Finish straight into the plane's slot of the private buffer
        # (one C pass; no numeric copy, no raw index assignment).
        .Call(
          "garry_finish_f32_into",
          res,
          4 * ((k - 1) * n_px + as.numeric(r0) * x_size),
          v,
          as.numeric(nodata),
          as.numeric(scale),
          as.numeric(offset),
          PACKAGE = "garry"
        )
        next
      }
      v <- as.numeric(v)
      if (length(nodata) == 1L) {
        v[!is.na(v) & v == nodata] <- NaN
      }
      v[is.na(v) & !is.nan(v)] <- NaN
      if (length(scale) == 1L) {
        v <- v * scale + offset
      }
      res[k, (r0 + 1L):(r0 + rows), ] <- matrix(v, nrow = rows, byrow = TRUE)
    }
    r0 <- r0 + rows
  }
  if (out == "raw_f32") {
    return(structure(
      res,
      gdim = as.integer(c(nb, y_size, x_size)),
      gdt = "f32"
    ))
  }
  res
}

# Open an existing output for update (the writer daemon re-opens
# host-created files; GTiff is single-writer, so exactly one process
# holds this handle at a time).
gdal_open_update <- function(path) {
  .gdal_handle_drop(path)
  # NUM_THREADS is a per-handle setting: the creation option on the
  # host's handle dies with it, so a GTiff re-opened here compressed
  # its tiles on one thread (14.9 ms a 768x768 plane against 3.5 ms
  # threaded, the writer-daemon tail of issue #25). The raw-cube VRT
  # has no compression and does not take the option.
  if (grepl("\\.vrt$", path, ignore.case = TRUE)) {
    return(methods::new(gdalraster::GDALRaster, path, read_only = FALSE))
  }
  methods::new(
    gdalraster::GDALRaster,
    path,
    read_only = FALSE,
    open_options = "NUM_THREADS=ALL_CPUS"
  )
}

# Create a raw-BSQ cube destination: a sparse zeroed .bin sized for the
# full cube plus the sibling VRT (georeference, dtype, nodata, band
# descriptions), returned open for update like any other output.
.raw_cube_create <- function(
  path,
  grid,
  n_bands,
  nodata = numeric(0),
  band_names = NULL,
  scale = numeric(0),
  offset = numeric(0)
) {
  if (!grid@dtype %in% c("f32", "f64")) {
    cli::cli_abort(paste0(
      "raw cubes hold f32/f64 only (got {.val {grid@dtype}}); ",
      "write a .tif for integer outputs"
    ))
  }
  bytes <- if (identical(grid@dtype, "f32")) 4L else 8L
  nx <- grid@dims[["x"]]
  ny <- grid@dims[["y"]]
  bin <- sub("\\.vrt$", ".bin", path, ignore.case = TRUE)
  total <- as.numeric(nx) * ny * n_bands * bytes
  con <- file(bin, "wb")
  seek(con, total - 1) # sparse allocation
  writeBin(raw(1L), con)
  close(con)
  gt_csv <- paste(
    formatC(grid@transform, format = "g", digits = 17, width = 1),
    collapse = ", "
  )
  xml <- .raw_bsq_vrt_xml(
    basename(bin),
    nx,
    ny,
    gt_csv,
    grid@crs,
    if (bytes == 4L) "Float32" else "Float64",
    n_bands,
    nodata = if (length(nodata) == 1L) nodata else NULL,
    descriptions = band_names,
    scale = if (length(scale) == 1L) scale else NULL,
    offset = if (length(offset) == 1L) offset else NULL
  )
  writeLines(xml, path)
  gdal_open_update(path)
}

#' Stage a GDAL raster as a raw-BSQ cube (`.bin` + sibling `.vrt`).
#'
#' Reads every band of `src` and writes garry's raw cube format:
#' band-sequential f32/f64 planes in a `.bin`, described by a
#' `VRTRawRasterBand` VRT that carries the georeference. Any GDAL
#' consumer reads the VRT normally; garry's reader recognises the shape
#' and reads the bin directly, which is many times faster than walking
#' the tiled GeoTIFF. Use it once on pipeline intermediates that are
#' read many times (per-year context cubes, prediction stacks).
#'
#' @param src Source path readable by GDAL.
#' @param dst_vrt Destination `.vrt` path (the `.bin` lands beside it).
#' @param slab_rows Rows per read/write slab (memory bound).
#' @return `dst_vrt`, invisibly.
#' @seealso [gdal_create_output()]
#' @export
stage_raw_cube <- function(src, dst_vrt, slab_rows = 512L) {
  if (!grepl("\\.vrt$", dst_vrt, ignore.case = TRUE)) {
    cli::cli_abort("{.arg dst_vrt} must end in .vrt")
  }
  meta <- gdal_grid_spec(src)
  ds <- methods::new(gdalraster::GDALRaster, src)
  nb <- ds$getRasterCount()
  bands <- seq_len(nb)
  dtn <- vapply(bands, function(b) ds$getDataTypeName(b), character(1))
  descs <- vapply(bands, function(b) ds$getDescription(b), character(1))
  # each band's own nodata and affine travel into the cube's VRT, so a
  # reader recovers them as from the source
  nodata <- vapply(bands, function(b) as.numeric(ds$getNoDataValue(b)), numeric(1))
  scale <- vapply(bands, function(b) as.numeric(ds$getScale(b)), numeric(1))
  offset <- vapply(bands, function(b) as.numeric(ds$getOffset(b)), numeric(1))
  ds$close()
  grid <- meta$grid
  if (any(dtn == "Float64")) {
    grid <- .grid_retype(grid, "f64")
  }
  nx <- grid@dims[["x"]]
  ny <- grid@dims[["y"]]
  bytes <- if (identical(grid@dtype, "f64")) 8L else 4L
  bin <- sub("\\.vrt$", ".bin", dst_vrt, ignore.case = TRUE)
  con <- file(bin, "wb")
  on.exit(close(con), add = TRUE)
  # band-major planes: per band, stream row slabs (raw values; the VRT
  # carries each band's nodata and affine)
  for (b in seq_len(nb)) {
    y0 <- 0L
    while (y0 < ny) {
      rows <- min(slab_rows, ny - y0)
      v <- as.numeric(gdal_read_window(src, b, 0L, y0, nx, rows))
      # gdal_read_window returns [y, x]; raw planes are row-major
      writeBin(as.numeric(t(matrix(v, nrow = rows))), con, size = bytes)
      y0 <- y0 + rows
    }
  }
  gt_csv <- paste(
    formatC(grid@transform, format = "g", digits = 17, width = 1),
    collapse = ", "
  )
  xml <- .raw_bsq_vrt_xml(
    basename(bin),
    nx,
    ny,
    gt_csv,
    grid@crs,
    if (bytes == 4L) "Float32" else "Float64",
    nb,
    nodata = nodata,
    descriptions = descs, # QA bands are found BY DESCRIPTION downstream
    scale = ifelse(scale == 1 & (is.na(offset) | offset == 0), NA, scale),
    offset = offset
  )
  writeLines(xml, dst_vrt)
  invisible(dst_vrt)
}

# ---------------------------------------------------------------------------
# Raw-BSQ cube format: a band-sequential .bin (exactly the raw store
# payload layout — row-major planes, band-major) beside a
# VRTRawRasterBand .vrt carrying georeference, dtype, nodata and band
# descriptions. Full GDAL interop through the VRT (reads AND update
# writes — the streamed writer daemon works unchanged), while garry's
# reader recognises the shape and bypasses the tile machinery.
# ---------------------------------------------------------------------------

# Parse cache: "path\x1fmtime" -> descriptor list, or FALSE for
# checked-and-not-a-raw-cube.
.raw_vrt_cache <- new.env(parent = emptyenv())

.raw_vrt_info <- function(path) {
  if (!grepl("\\.vrt$", path, ignore.case = TRUE)) {
    return(NULL)
  }
  key <- paste0(path, "\x1f", as.numeric(file.mtime(path)))
  hit <- .raw_vrt_cache[[key]]
  if (!is.null(hit)) {
    return(if (isFALSE(hit)) NULL else hit)
  }
  info <- tryCatch(.raw_vrt_parse(path), error = function(e) NULL)
  .raw_vrt_cache[[key]] <- info %||% FALSE
  info
}

# Bytes per sample for a GDAL data-type name.
.gdal_dtype_bytes <- function(dt) {
  b <- c(
    Byte = 1L,
    Int8 = 1L,
    UInt16 = 2L,
    Int16 = 2L,
    UInt32 = 4L,
    Int32 = 4L,
    UInt64 = 8L,
    Int64 = 8L,
    Float32 = 4L,
    Float64 = 8L
  )[[dt]]
  if (is.null(b)) {
    cli::cli_abort("Unsupported buffer dtype {.val {dt}}.")
  }
  b
}

# Build a VRTRawRasterBand dataset XML over a raw band-sequential (BSQ) buffer, so
# GDAL reads it with zero decode. Band b's plane starts at (b-1) * nx * ny * bytes;
# pixels are row-major within it. `src` is the .bin basename, referenced as a
# relativeToVRT sibling (the VRT must be written beside it): GDAL refuses a raw
# band pointing at an arbitrary absolute path unless the source is a sibling/child
# of the VRT (or GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE is set), which this
# satisfies rather than loosening the global config.
.raw_bsq_vrt_xml <- function(
  src,
  nx,
  ny,
  gt_csv,
  wkt,
  dtype,
  nbands,
  nodata = NULL,
  descriptions = NULL,
  scale = NULL,
  offset = NULL
) {
  bytes <- .gdal_dtype_bytes(dtype)
  plane <- as.numeric(nx) * as.numeric(ny) * bytes
  num <- function(v) formatC(v, format = "g", digits = 17, width = 1)
  # per-band value (a scalar applies to every band); NA = unset
  per_band <- function(v, b) {
    if (!length(v)) NA else if (length(v) == 1L) v[[1L]] else v[[b]]
  }
  bands_xml <- vapply(
    seq_len(nbands),
    function(b) {
      d <- if (b <= length(descriptions)) descriptions[[b]] else ""
      desc <- if (!is.na(d) && nzchar(d)) {
        .glue("\n    <Description>{.xml_escape(d)}</Description>")
      } else {
        ""
      }
      nd <- per_band(nodata, b)
      ndxml <- if (!is.na(nd) || is.nan(nd)) {
        .glue("\n    <NoDataValue>{num(nd)}</NoDataValue>")
      } else {
        ""
      }
      sc <- per_band(scale, b)
      of <- per_band(offset, b)
      afxml <- if (!is.na(sc)) {
        .glue(
          "\n    <Offset>{num(if (is.na(of)) 0 else of)}</Offset>",
          "\n    <Scale>{num(sc)}</Scale>"
        )
      } else {
        ""
      }
      .glue(
        '  <VRTRasterBand dataType="{dtype}" band="{b}" ',
        'subClass="VRTRawRasterBand">{desc}',
        '\n    <SourceFilename relativeToVRT="1">{.xml_escape(src)}</SourceFilename>',
        "\n    <ImageOffset>",
        "{formatC((b - 1) * plane, format = 'f', digits = 0)}</ImageOffset>",
        "\n    <PixelOffset>{bytes}</PixelOffset>",
        "\n    <LineOffset>{as.integer(nx * bytes)}</LineOffset>{ndxml}{afxml}",
        "\n  </VRTRasterBand>"
      )
    },
    ""
  )
  .glue(
    '<VRTDataset rasterXSize="{nx}" rasterYSize="{ny}">',
    "\n  <SRS>{.xml_escape(wkt)}</SRS>\n  <GeoTransform>{gt_csv}</GeoTransform>",
    "\n{paste(bands_xml, collapse = '\n')}\n</VRTDataset>"
  )
}

# Escape text for an XML element body.
.xml_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  gsub("\"", "&quot;", x, fixed = TRUE)
}

# Strict recognition of the .raw_bsq_vrt_xml shape: every band a
# VRTRawRasterBand over ONE relativeToVRT sibling, uniform Float32 or
# Float64, exact BSQ strides, bin present at the implied size. Any
# deviation returns NULL (the GDAL path handles it).
.raw_vrt_parse <- function(path) {
  xml <- paste(readLines(path, warn = FALSE), collapse = "\n")
  if (!grepl('subClass="VRTRawRasterBand"', xml, fixed = TRUE)) {
    return(NULL)
  }
  hdr <- regmatches(
    xml,
    regexec(
      'rasterXSize="(\\d+)"[^>]*rasterYSize="(\\d+)"',
      xml
    )
  )[[1L]]
  if (length(hdr) < 3L) {
    return(NULL)
  }
  nx <- as.integer(hdr[[2L]])
  ny <- as.integer(hdr[[3L]])
  bands <- regmatches(
    xml,
    gregexpr(
      '(?s)<VRTRasterBand.*?</VRTRasterBand>',
      xml,
      perl = TRUE
    )
  )[[1L]]
  if (!length(bands)) {
    return(NULL)
  }
  g1 <- function(b, re) {
    m <- regmatches(b, regexec(re, b, perl = TRUE))[[1L]]
    if (length(m) < 2L) NA_character_ else m[[2L]]
  }
  dt <- vapply(bands, g1, "", 'dataType="([^"]+)"', USE.NAMES = FALSE)
  if (length(unique(dt)) != 1L || !dt[[1L]] %in% c("Float32", "Float64")) {
    return(NULL)
  }
  if (!all(grepl('subClass="VRTRawRasterBand"', bands, fixed = TRUE))) {
    return(NULL)
  }
  src <- vapply(
    bands,
    g1,
    "",
    '<SourceFilename relativeToVRT="1">([^<]+)</SourceFilename>',
    USE.NAMES = FALSE
  )
  if (anyNA(src) || length(unique(src)) != 1L) {
    return(NULL)
  }
  bno <- as.integer(vapply(bands, g1, "", ' band="(\\d+)"', USE.NAMES = FALSE))
  ioff <- as.numeric(vapply(
    bands,
    g1,
    "",
    "<ImageOffset>(\\d+)</ImageOffset>",
    USE.NAMES = FALSE
  ))
  poff <- as.integer(vapply(
    bands,
    g1,
    "",
    "<PixelOffset>(\\d+)</PixelOffset>",
    USE.NAMES = FALSE
  ))
  loff <- as.integer(vapply(
    bands,
    g1,
    "",
    "<LineOffset>(\\d+)</LineOffset>",
    USE.NAMES = FALSE
  ))
  nd <- suppressWarnings(as.numeric(vapply(
    bands,
    g1,
    "",
    "<NoDataValue>([^<]+)</NoDataValue>",
    USE.NAMES = FALSE
  )))
  bytes <- if (dt[[1L]] == "Float32") 4L else 8L
  plane <- as.numeric(nx) * ny * bytes
  nb <- length(bands)
  ok <- !anyNA(bno) &&
    identical(bno, seq_len(nb)) &&
    !anyNA(ioff) &&
    all(ioff == (bno - 1) * plane) &&
    all(poff == bytes) &&
    all(loff == nx * bytes)
  if (!isTRUE(ok)) {
    return(NULL)
  }
  bin <- file.path(dirname(path), src[[1L]])
  if (!file.exists(bin) || file.size(bin) < nb * plane) {
    return(NULL)
  }
  list(
    bin = bin,
    nx = nx,
    ny = ny,
    nb = nb,
    bytes = bytes,
    dtype = if (bytes == 4L) "f32" else "f64",
    nodata = if (length(unique(nd)) == 1L) nd[[1L]] else NA_real_
  )
}

# The fast read: per band, seek to the window's first full-width row,
# read y_size rows in one gulp, column-subset when the window is
# narrower than the raster. Output shapes/dtypes/nodata semantics are
# byte-identical to the GDAL path (the equivalence test holds them
# together).
.raw_vrt_read <- function(
  info,
  band,
  x_off,
  y_off,
  x_size,
  y_size,
  nodata,
  out,
  scale = numeric(0),
  offset = numeric(0)
) {
  if (
    x_off < 0 || y_off < 0 || x_size < 1 || y_size < 1 ||
      x_off + x_size > info$nx || y_off + y_size > info$ny
  ) {
    cli::cli_abort(
      "Access window out of range: {x_off},{y_off} {x_size}x{y_size} on a {info$nx}x{info$ny} raw cube."
    )
  }
  con <- file(info$bin, "rb")
  on.exit(close(con))
  es <- info$bytes
  nx <- info$nx
  full <- x_off == 0L && x_size == nx
  nb <- length(band)
  n_px <- as.numeric(y_size) * x_size
  # pure-raw hot path: f32 source, no sentinel to map — the fused-read
  # shape (SI predict): plane-range reads, staying in raw end to end.
  # Partial-width windows subset COLUMN BYTES with one precomputed
  # index (each output row is a contiguous byte run inside its
  # full-width row), so no numeric round-trip either way.
  if (
    out == "raw_f32" && es == 4L && length(nodata) != 1L && length(scale) != 1L
  ) {
    idx <- if (!full) {
      within <- (x_off * 4L + 1L):((x_off + x_size) * 4L)
      # in double: rows x width x 4 bytes passes 2^31 on large cubes
      rep((seq_len(y_size) - 1) * (nx * 4), each = length(within)) +
        within
    }
    parts <- vector("list", nb)
    for (k in seq_len(nb)) {
      seek(
        con,
        ((band[[k]] - 1) * as.numeric(nx) * info$ny + as.numeric(y_off) * nx) *
          4
      )
      p <- readBin(con, "raw", n = as.numeric(y_size) * nx * 4)
      parts[[k]] <- if (full) p else p[idx]
    }
    v <- if (nb == 1L) parts[[1L]] else do.call(c, parts)
    if (nb == 1L) {
      return(structure(v, gdim = c(y_size, x_size), gdt = "f32"))
    }
    return(structure(v, gdim = as.integer(c(nb, y_size, x_size)), gdt = "f32"))
  }
  # numeric path (matrix out, f64, sentinel mapping, partial width)
  res <- if (nb > 1L && out != "raw_f32") {
    array(NA_real_, c(nb, y_size, x_size))
  } else {
    NULL
  }
  raws <- if (out == "raw_f32") vector("list", nb)
  single <- NULL
  for (k in seq_len(nb)) {
    seek(
      con,
      ((band[[k]] - 1) * as.numeric(nx) * info$ny + as.numeric(y_off) * nx) * es
    )
    v <- readBin(con, "numeric", n = as.numeric(y_size) * nx, size = es)
    if (!full) {
      # row-major rows: as an (nx x y_size) matrix each COLUMN is one
      # image row; subsetting its rows takes the window's columns, and
      # flattening back is row-major again
      v <- as.numeric(matrix(v, nrow = nx)[
        (x_off + 1L):(x_off + x_size),
        ,
        drop = FALSE
      ])
    }
    if (length(nodata) == 1L) {
      v[!is.na(v) & v == nodata] <- NaN
    }
    v[is.na(v) & !is.nan(v)] <- NaN
    if (length(scale) == 1L) {
      v <- v * scale + offset
    }
    if (out == "raw_f32") {
      raws[[k]] <- writeBin(v, raw(), size = 4L)
    } else if (nb > 1L) {
      res[k, , ] <- matrix(v, nrow = y_size, byrow = TRUE)
    } else {
      single <- v
    }
  }
  if (out == "raw_f32") {
    v <- if (nb == 1L) raws[[1L]] else do.call(c, raws)
    if (nb == 1L) {
      return(structure(v, gdim = c(y_size, x_size), gdt = "f32"))
    }
    return(structure(v, gdim = as.integer(c(nb, y_size, x_size)), gdt = "f32"))
  }
  if (nb > 1L) {
    return(res)
  }
  matrix(single, nrow = y_size, byrow = TRUE)
}

# Reverse dtype map for writing.
.gdal_dtype_rev <- c(
  u8 = "Byte",
  i8 = "Int8",
  u16 = "UInt16",
  i16 = "Int16",
  u32 = "UInt32",
  i32 = "Int32",
  u64 = "UInt64",
  i64 = "Int64",
  f32 = "Float32",
  f64 = "Float64"
)

#' Build a warped VRT of a source onto an exact target grid.
#'
#' Delegates every pixel of cross-CRS math to the GDAL warper:
#' `-te`/`-ts` pin the output grid exactly to `target_grid`.
#' A source nodata goes to the warper as both `-srcnodata` and
#' `-dstnodata`, so it never enters resampling and area outside the source
#' footprint reads as nodata; float targets without one get `-dstnodata
#' nan`.
#'
#' @param src_path Source path/VSI URL. One source: gdalwarp writes a
#'   VRT from a single input only. A multi-path source node is read by
#'   `gdal_warp_window()` instead.
#' @param band 1-based source band (the VRT has this single band).
#' @param target_grid `GridSpec` to warp onto.
#' @param resampling GDAL resampling method name.
#' @param src_nodata Source sentinel (length 0 or 1), from the SourceNode.
#' @return Path to the VRT file (in `tempdir()`).
gdal_warp_vrt <- function(
  src_path,
  band,
  target_grid,
  resampling,
  src_nodata = numeric(0)
) {
  if (length(src_path) != 1L) {
    cli::cli_abort("gdal_warp_vrt() takes one source; several are read by gdal_warp_window().")
  }
  src_path <- .gdal_href(src_path) # bare https would pull the whole file
  vrt <- tempfile(fileext = ".vrt")
  num <- function(v) formatC(v, format = "g", digits = 17, width = 1)
  args <- c(
    "-of",
    "VRT",
    "-te",
    num(target_grid@extent[1L]),
    num(target_grid@extent[2L]),
    num(target_grid@extent[3L]),
    num(target_grid@extent[4L]),
    "-ts",
    target_grid@dims[["x"]],
    target_grid@dims[["y"]],
    "-r",
    resampling,
    as.vector(rbind("-b", band)),
    "-et",
    "0"
  ) # exact transformer: correctness over warp speed
  if (length(src_nodata) == 1L) {
    # The node's sentinel, whether the file declares it or the user did:
    # the warper must leave it out of resampling, and cells outside the
    # footprint read as it (then NaN, like every other sentinel cell).
    args <- c(args, "-srcnodata", num(src_nodata), "-dstnodata", num(src_nodata))
  } else if (.dtype_family(target_grid@dtype) == "float") {
    args <- c(args, "-dstnodata", "nan")
  }
  do_warp <- function() {
    gdalraster::warp(
      src_path,
      vrt,
      t_srs = target_grid@crs,
      cl_arg = args,
      quiet = TRUE
    )
  }
  # warp opens the source internally (bypassing .gdal_handle), so it
  # needs the same remote-open hygiene scoping
  ok <- if (any(vapply(src_path, .gdal_opens_remote, logical(1)))) {
    .gdal_quiet_remote(do_warp())
  } else {
    do_warp()
  }
  if (!isTRUE(ok)) {
    cli::cli_abort("gdalwarp to VRT failed for {.path {src_path}}")
  }
  vrt
}

#' GDAL runtime version as an integer `GDAL_VERSION_NUM` (adapter).
#'
#' `MAJOR*1000000 + MINOR*10000 + REV*100`, so 3.9.0 is `3090000`. `NA` if it
#' cannot be parsed. garry needs >= 3.9 for the GTI (GDAL Tile Index) mosaic
#' driver that backs `lazy_dataset()`.
#'
#' @return Integer version number, or `NA_integer_`.
#' @keywords internal
gdal_version_num <- function() {
  n <- suppressWarnings(as.integer(gdalraster::gdal_version()[[2L]]))
  if (length(n) != 1L || is.na(n)) NA_integer_ else n
}

#' GDAL runtime version as a human string (adapter).
#' @return Character, e.g. `"GDAL 3.9.0, released ..."`.
#' @keywords internal
gdal_version_str <- function() gdalraster::gdal_version()[[1L]]

#' Mosaic already-grid-aligned rasters into a VRT (adapter).
#'
#' `gdalbuildvrt` of same-grid single-band rasters: overlapping pixels take the
#' LAST input, so pass `files` in ascending priority (latest datetime last, to
#' match the highest-on-top overlap rule). Used to assemble multi-tile
#' mosaics (e.g. the file form of [lazy_dataset()]).
#'
#' `gdalbuildvrt` takes only north-up sources in one projection and
#' SKIPS, with a warning, any other: a tile stored south-up (positive
#' north-south pixel size; every AEF tile, seen 2026-09-25) or a tile
#' in the neighbouring UTM zone (ESD tiles on the MGRS grid, which
#' overlaps a zone boundary). A skipped tile would be a hole, or with
#' every tile skipped no mosaic at all, so a build that lost a source is
#' an error here. Sources like that do not belong in a mosaic: the file
#' form of [lazy_dataset()] keeps them as a multi-path source node and
#' the warper reads them together (`gdal_warp_window()`).
#'
#' @param dst Output VRT path.
#' @param files Grid-aligned input rasters, low-to-high priority.
#' @return `dst`.
#' @keywords internal
gdal_mosaic_vrt <- function(
  dst,
  files,
  te = NULL,
  ts = NULL,
  vrtnodata = NULL
) {
  args <- character(0)
  if (!is.null(te)) {
    te <- as.numeric(te)
    if (is.null(ts)) {
      cli::cli_abort("`te` requires `ts`.")
    }
    ts <- as.numeric(ts)
    tr <- c((te[[3L]] - te[[1L]]) / ts[[1L]], (te[[4L]] - te[[2L]]) / ts[[2L]])
    args <- c(
      "-te",
      formatC(te, format = "g", digits = 16, width = 1),
      "-tr",
      formatC(tr, format = "g", digits = 16, width = 1)
    )
  }
  if (length(vrtnodata)) {
    args <- c(
      args,
      "-vrtnodata",
      formatC(vrtnodata[[1L]], format = "g", digits = 16, width = 1)
    )
  }
  do_build <- function() {
    gdalraster::buildVRT(
      dst,
      files,
      cl_arg = if (length(args)) args else NULL,
      quiet = TRUE
    )
  }
  if (any(.gdal_is_remote(files))) {
    .gdal_quiet_remote(do_build())
  } else {
    do_build()
  }
  if (!file.exists(dst)) {
    cli::cli_abort("buildVRT mosaic failed.")
  }
  # one <SourceFilename> per band per source: count distinct sources
  xml <- paste(readLines(dst, warn = FALSE), collapse = "\n")
  srcs <- regmatches(xml, gregexpr("<SourceFilename[^>]*>[^<]*</SourceFilename>", xml))[[1L]]
  n_in <- length(unique(sub("^<SourceFilename[^>]*>([^<]*)</SourceFilename>$", "\\1", srcs)))
  if (n_in < length(unique(files))) {
    unlink(dst)
    cli::cli_abort(
      "buildVRT mosaic took {n_in} of {length(files)} source{?s}; the rest were skipped (see the GDAL warnings)."
    )
  }
  dst
}

# Header probes of several sources: geotransform, projection, size.
.source_probes <- function(files) {
  lapply(files, function(f) {
    ds <- .gdal_handle(f)
    list(gt = ds$getGeoTransform(), srs = ds$getProjection(),
         nx = ds$getRasterXSize(), ny = ds$getRasterYSize(),
         nb = ds$getRasterCount(), dims = .gdal_band_dims(ds))
  })
}

# Can gdalbuildvrt mosaic these sources: all north-up, one projection.
.mosaicable <- function(probes) {
  ref <- probes[[1L]]$srs
  all(vapply(probes, function(p) {
    p$gt[[6L]] < 0 && p$gt[[3L]] == 0 && p$gt[[5L]] == 0 &&
      (identical(p$srs, ref) ||
         isTRUE(tryCatch(gdalraster::srs_is_same(p$srs, ref), error = function(e) FALSE)))
  }, NA))
}

# The planning grid of a multi-path source node: the first source's
# projection, resolution and type, over the union of every source's
# footprint (a footprint in another projection is transformed), snapped
# outward to the first source's lattice and north-up. Chunking and the
# read plan run on it; the warper serves each read from all sources.
.multi_source_meta <- function(files, probes) {
  m1 <- gdal_grid_spec(files[[1L]])
  g1 <- m1$grid
  gt <- g1@transform
  res <- c(gt[[2L]], abs(gt[[6L]]))
  exts <- lapply(probes, function(p) {
    e <- c(p$gt[[1L]], p$gt[[4L]] + p$ny * p$gt[[6L]], p$gt[[1L]] + p$nx * p$gt[[2L]], p$gt[[4L]])
    e <- c(min(e[c(1L, 3L)]), min(e[c(2L, 4L)]), max(e[c(1L, 3L)]), max(e[c(2L, 4L)]))
    same <- identical(p$srs, probes[[1L]]$srs) ||
      isTRUE(tryCatch(gdalraster::srs_is_same(p$srs, probes[[1L]]$srs), error = function(e) FALSE))
    if (same) e else gdalraster::transform_bounds(e, p$srs, probes[[1L]]$srs)
  })
  u <- c(min(vapply(exts, `[[`, 0, 1L)), min(vapply(exts, `[[`, 0, 2L)),
         max(vapply(exts, `[[`, 0, 3L)), max(vapply(exts, `[[`, 0, 4L)))
  x0 <- gt[[1L]]; y0 <- gt[[4L]]
  te <- c(x0 + floor((u[[1L]] - x0) / res[[1L]]) * res[[1L]],
          y0 - ceiling((y0 - u[[2L]]) / res[[2L]]) * res[[2L]],
          x0 + ceiling((u[[3L]] - x0) / res[[1L]]) * res[[1L]],
          y0 - floor((y0 - u[[4L]]) / res[[2L]]) * res[[2L]])
  m1$grid <- grid_spec(g1@crs, extent = te, res = res, dtype = g1@dtype)
  m1
}

#' Create an output raster for a grid.
#'
#' A single non-spatial dim ("t" or "band") maps to bands; more than
#' one is an error. A `.tif` destination writes a tiled GTiff; a
#' `.vrt` destination writes a raw-BSQ cube (`.bin` + sibling
#' `VRTRawRasterBand` VRT — the intermediate format whose reads bypass
#' GDAL's tile machinery; see [stage_raw_cube()]).
#'
#' @param path Destination path.
#' @param grid Output `GridSpec`.
#' @param nodata Optional sentinel to record in metadata (all bands).
#' @param options GTiff creation options. `NULL` (default) uses tiled DEFLATE
#'   (`TILED=YES`, 256x256 blocks, `BIGTIFF=IF_SAFER`) plus `INTERLEAVE=BAND`
#'   for multi-band grids. Band interleave matters: GDAL's GTiff defaults
#'   (pixel interleave, full-width 1-row strips) make every later per-band
#'   read decompress ALL bands of each strip, which amplifies read cost by
#'   the band count on files garry itself wrote.
#' @param band_names Optional character vector of band descriptions, in band
#'   order; written as each band's GDAL description (shows in `gdalinfo`).
#' @param dtype Optional dtype override for the created file (else the
#'   grid's dtype).
#' @param scale,offset Optional band scale/offset metadata written on every
#'   band, so readers (QGIS, GDAL, `scale = TRUE` reads) recover
#'   `stored * scale + offset`.
#' @return An open dataset object; caller must `$close()`.
gdal_create_output <- function(
  path,
  grid,
  nodata = numeric(0),
  options = NULL,
  band_names = NULL,
  dtype = NULL,
  scale = numeric(0),
  offset = numeric(0)
) {
  .gdal_handle_drop(path) # a cached reader would serve the old file
  if (!is.null(dtype)) {
    grid <- .grid_retype(grid, dtype)
  }
  dt <- .gdal_dtype_rev[[grid@dtype]]
  if (is.null(dt)) {
    cli::cli_abort("cannot write dtype: {.val {grid@dtype}}")
  }
  outer <- grid@dims[!names(grid@dims) %in% c("x", "y")]
  if (length(outer) > 1L) {
    cli::cli_abort(
      "cannot write a grid with more than one non-spatial dim ({names(outer)})"
    )
  }
  n_bands <- if (length(outer) == 1L) as.integer(outer[[1L]]) else 1L
  # A ".vrt" destination writes a raw-BSQ cube (.bin + sibling VRT)
  # instead of a GTiff: the intermediate format whose reads bypass the
  # tile machinery (~9x on multi-band windows). Update-writes go
  # through the VRT, so the streamed writer daemon works unchanged.
  if (grepl("\\.vrt$", path, ignore.case = TRUE)) {
    if (length(options)) {
      cli::cli_abort("{.arg options} do not apply to a {.path .vrt} raw cube.")
    }
    return(.raw_cube_create(path, grid, n_bands, nodata, band_names, scale, offset))
  }
  if (is.null(options)) {
    # NUM_THREADS parallelises per-tile DEFLATE inside the (single)
    # writer daemon: the streamed-write flush of a 64-band AEF cube was
    # a 57 s single-threaded backlog after the drain (2026-08-12).
    # Tiles compress independently, so output bytes are unchanged.
    options <- c(
      "COMPRESS=DEFLATE",
      "TILED=YES",
      "BLOCKXSIZE=256",
      "BLOCKYSIZE=256",
      "BIGTIFF=IF_SAFER",
      "NUM_THREADS=ALL_CPUS"
    )
    if (n_bands > 1L) options <- c(options, "INTERLEAVE=BAND")
  } else if (!any(grepl("^NUM_THREADS=", options, ignore.case = TRUE))) {
    # user options keep the threaded compression unless they set it
    options <- c(options, "NUM_THREADS=ALL_CPUS")
  }
  ds <- gdalraster::create(
    "GTiff",
    path,
    grid@dims[["x"]],
    grid@dims[["y"]],
    n_bands,
    dt,
    options = options,
    return_obj = TRUE
  )
  ds$setGeoTransform(grid@transform)
  ds$setProjection(grid@crs)
  if (length(nodata) == 1L) {
    for (b in seq_len(n_bands)) {
      ds$setNoDataValue(b, nodata)
    }
  }
  if (length(scale) == 1L) {
    for (b in seq_len(n_bands)) {
      ds$setScale(b, scale)
      ds$setOffset(b, if (length(offset) == 1L) offset else 0)
    }
  }
  if (length(band_names) > 0L) {
    for (b in seq_len(min(n_bands, length(band_names)))) {
      if (nzchar(band_names[[b]])) ds$setDescription(b, band_names[[b]])
    }
  }
  ds
}

#' Write a garry-oriented matrix into an open output dataset.
#'
#' NaN cells are converted back to the sink `nodata` value when given;
#' writing NaN into an integer band without a sentinel is an error.
#'
#' @param ds Open dataset from [gdal_create_output()].
#' @param x_off,y_off 0-based destination offsets.
#' @param m `[y, x]` matrix.
#' @param dtype Output dtype (for the NaN check).
#' @param nodata Optional sentinel for NaN demotion.
#' @param band 1-based destination band.
#' @param plane For a rank-3 `(band, y, x)` raw store payload, the
#'   1-based plane to write (taken by byte offset, no copy of the rest).
#' @return Invisibly, `NULL`.
gdal_write_window <- function(
  ds,
  x_off,
  y_off,
  m,
  dtype,
  nodata = numeric(0),
  band = 1L,
  plane = 1L
) {
  w <- .write_vec(m, dtype, nodata, plane)
  ds$write(as.integer(band), x_off, y_off, w$nc, w$nr, w$v)
  invisible(NULL)
}

# The vector a window write hands GDAL, in its row-major order, with
# its window size: list(v, nr, nc). Split from gdal_write_window() so
# the read pool can prepare a write the writer daemon only performs.
.write_vec <- function(m, dtype, nodata = numeric(0), plane = 1L) {
  if (.sv_is(m)) {
    # Raw store payloads are already in GDAL's row-major write order;
    # one C pass takes the plane out and folds NaN to the sentinel.
    # Quantized sink payloads arrive as ready-to-write integers from
    # g_quantize() at the producer (design: one device quantizer for
    # every route; the old writer-side round((v - offset) / scale) is
    # gone, so the single writer daemon only does IO).
    d <- .sv_dim(m)
    nr <- d[[length(d) - 1L]]
    nc <- d[[length(d)]]
    v <- .sv_plane_vec(m, plane, nodata, .dtype_family(dtype) != "float")
    if (is.integer(v)) {
      return(list(v = v, nr = nr, nc = nc))
    }
  } else {
    nr <- nrow(m)
    nc <- ncol(m)
    v <- if (is.integer(m)) as.integer(t(m)) else as.numeric(t(m))
    if (length(nodata) == 1L) {
      v[is.na(v)] <- nodata
    }
  }
  if (length(nodata) != 1L && .dtype_family(dtype) != "float" && anyNA(v)) {
    cli::cli_abort(paste0(
      "result contains nodata (NaN) but no {.arg nodata} sentinel was ",
      "given for integer output dtype {.val {dtype}}"
    ))
  }
  list(v = v, nr = nr, nc = nc)
}

#' Extract raster values at points (adapter).
#'
#' D13: the only home for the `gdalraster::pixel_extract` call. Handles
#' interpolation, kernel windows, point reprojection and the RAM guard
#' itself, and reads only the blocks holding points -- so garry delegates
#' rather than reimplementing any of it.
#'
#' @param raster Path or `GDALRaster` object.
#' @param ... Passed to [gdalraster::pixel_extract()].
#' @return As [gdalraster::pixel_extract()].
#' @keywords internal
gdal_pixel_extract <- function(raster, ...) {
  gdalraster::pixel_extract(raster, ...)
}

# Whole-file gdal_translate (D13: the only home for the gdalraster call).
# Used by write_tif(cog = TRUE) to finalise a streamed GeoTIFF into COG
# layout. Returns TRUE on success.
gdal_translate_file <- function(src, dst, cl_arg) {
  gdalraster::translate(src, dst, cl_arg = cl_arg, quiet = TRUE)
}

# Warp sources straight into a caller-held f32 buffer via GDAL's MEM:::
# DATAPOINTER driver (warp-on-read, the GDAL-direct fast path): GDAL reads
# (windowed vsicurl for remote items), reprojects and mosaics `srcs` into `buf`
# in place, in the order given (last source wins on overlap). `-r near` and
# nan dst-nodata match the composite path. Returns the same `buf`, now filled.
# D13: the sole home for the direct-to-memory GDAL warp mechanics (the MEM
# driver open gate, the raw data pointer, and the warp) -- callers stay clean.
gdal_warp_to_buffer <- function(
  buf,
  nx,
  ny,
  gtstr,
  wkt,
  srcs,
  srcnodata = NULL,
  resampling = "near",
  band = NULL
) {
  gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES") # >=3.10 gate
  # `buf` is a RAW f32 byte vector (the raw-f32 store, D19-D21). The public
  # gdalraster::rvector_to_MEM() infers the band type from the R vector type
  # (integer/double/complex) and cannot expose raw bytes as Float32, so the
  # pure-R way to zero-copy-warp into an f32 buffer is the data pointer plus an
  # explicit DATATYPE=Float32 MEM DSN. get_data_ptr() is exported from
  # gdalraster 2.7.0, hence the version floor.
  ptr <- gdalraster::get_data_ptr(buf)
  # several bands fill band-sequential planes (the MEM default BANDOFFSET)
  nb <- max(1L, length(band))
  dsn <- .glue(
    "MEM:::DATAPOINTER={ptr},PIXELS={nx},LINES={ny},BANDS={nb},",
    "DATATYPE=Float32,GEOTRANSFORM={gtstr}"
  )
  o <- methods::new(gdalraster::GDALRaster, dsn, FALSE)
  o$setProjection(wkt)
  cl <- c("-r", resampling, "-q", "-dstnodata", "nan")
  if (length(srcnodata) == 1L) {
    cl <- c(cl, "-srcnodata", format(srcnodata, scientific = FALSE))
  }
  if (length(band) == 1L) {
    cl <- c(cl, "-srcband", as.character(as.integer(band))) # GDAL >= 3.7
  } else if (length(band) > 1L) {
    cl <- c(cl, as.vector(rbind(
      "-srcband", as.integer(band), "-dstband", seq_along(band)
    )))
  }
  gdalraster::warp(srcs, o, "", cl_arg = cl)
  o$close()
  buf
}

# Read one window of a multi-path source node: every source's `band`
# warped straight into the window's f32 buffer in ONE gdalwarp (GDAL
# reads each source's blocks once, reprojects, mosaics; later sources
# win on overlap). No mosaic VRT (gdalbuildvrt cannot hold south-up or
# cross-projection tiles) and no warped VRT (gdalwarp writes a VRT from
# a single source only, and a warped VRT re-warps every band of a block
# whenever one band is read, which a per-band fan-out multiplies by the
# band count). The window is in `grid` pixels (a chunk with its halo);
# cells outside every source come back NaN.
#
# Several bands (a collapsed band stack, e.g. one year of a Zarr array
# across UTM zones) warp together into a (band, y, x) cube. The sources
# go to the warper as cached handles, not names: a name reopens the
# source on every call, and a Zarr store's open costs seconds and drops
# the decoded chunks the next band would reuse.
gdal_warp_window <- function(
  paths,
  band,
  grid,
  x_off,
  y_off,
  x_size,
  y_size,
  resampling = "near",
  nodata = numeric(0),
  out = c("matrix", "raw_f32"),
  scale = numeric(0),
  offset = numeric(0)
) {
  out <- rlang::arg_match(out)
  nb <- length(band)
  gt <- grid@transform
  win <- c(gt[[1L]] + x_off * gt[[2L]], gt[[2L]], 0, gt[[4L]] + y_off * gt[[6L]], 0, gt[[6L]])
  gtstr <- paste(formatC(win, format = "g", digits = 17, width = 1), collapse = "/")
  n_px <- as.numeric(x_size) * y_size
  for (p in paths[vapply(paths, .gdal_is_zarr, logical(1))]) {
    .gdal_zarr_budget(p, character(0), band, n_px)
  }
  # every source must stay open through the warp: read daemons cache one
  # handle by default, so lift the cap to the source count meanwhile
  old <- options(
    garry.handle_cache_max = max(garry_opt("handle_cache_max"), length(paths))
  )
  on.exit(options(old), add = TRUE)
  srcs <- lapply(paths, .gdal_handle)
  buf <- rep(writeBin(NaN, raw(), size = 4L), n_px * nb)
  warp <- function() {
    gdal_warp_to_buffer(
      buf, x_size, y_size, gtstr, grid@crs, srcs,
      srcnodata = nodata, resampling = resampling, band = band
    )
  }
  # the warper reloads a Zarr band's dimension metadata, repeating the
  # open's coordinate probes and their noise (see .gdal_handle())
  buf <- if (any(vapply(paths, .gdal_is_zarr, logical(1)))) {
    .gdal_quiet_errors(warp())
  } else {
    warp()
  }
  if (nb > 1L && out == "raw_f32" && length(scale) == 0L) {
    # the warped buffer is already the band-sequential f32 payload, nodata
    # NaN (-dstnodata nan): hand it over as is
    return(structure(buf, gdim = as.integer(c(nb, y_size, x_size)), gdt = "f32"))
  }
  v <- readBin(buf, "numeric", n = n_px * nb, size = 4L)
  .gdal_finish_planes(v, nb, y_size, x_size, scale, offset, out)
}

# Band-sequential row-major planes `v` (nodata already NaN) in the
# requested output form: one band's matrix or raw f32 payload, or a
# (band, y, x) cube or rank-3 raw f32 payload, after the band affine.
.gdal_finish_planes <- function(v, nb, y_size, x_size, scale, offset, out) {
  n_px <- as.numeric(x_size) * y_size
  if (nb == 1L) {
    return(.gdal_finish_vec(v, y_size, x_size, numeric(0), scale, offset, out))
  }
  if (out == "raw_f32") {
    # finish every plane in one pass; the planes are already in order
    return(structure(
      as.vector(.gdal_finish_vec(v, nb * y_size, x_size, numeric(0), scale, offset, out)),
      gdim = as.integer(c(nb, y_size, x_size)),
      gdt = "f32"
    ))
  }
  cube <- array(NA_real_, c(nb, y_size, x_size))
  for (k in seq_len(nb)) {
    cube[k, , ] <- .gdal_finish_vec(
      v[(k - 1) * n_px + seq_len(n_px)],
      y_size,
      x_size,
      numeric(0),
      scale,
      offset,
      out
    )
  }
  cube
}

# Read one window of a multi-path source whose every source lies on the
# target's pixels (.rio_direct_multi_spec()): each source's share of the
# window read directly (a south-up one with its rows reversed) and laid
# over the window in source order, a later source's valid cells winning,
# as gdal_warp_window() mosaics them. Cells no source covers stay NaN.
# A window inside a single source is that source's own window read.
gdal_read_window_multi <- function(
  paths,
  band,
  x_off,
  y_off,
  x_size,
  y_size,
  decim,
  nodata = numeric(0),
  out = c("matrix", "raw_f32"),
  scale = numeric(0),
  offset = numeric(0)
) {
  out <- rlang::arg_match(out)
  # every source stays open from window to window (see gdal_warp_window())
  old <- options(
    garry.handle_cache_max = max(garry_opt("handle_cache_max"), length(paths))
  )
  on.exit(options(old), add = TRUE)
  parts <- list()
  for (i in seq_along(paths)) {
    s <- decim$srcs[[i]]
    sx <- x_off + s$x_off # the window's origin in source pixels
    sy <- y_off + s$y_off
    c0 <- max(0L, -sx)
    c1 <- min(x_size, s$nx - sx)
    r0 <- max(0L, -sy)
    r1 <- min(y_size, s$ny - sy)
    if (c1 > c0 && r1 > r0) {
      parts[[length(parts) + 1L]] <- list(
        i = i,
        sx = sx,
        sy = sy,
        c0 = c0,
        c1 = c1,
        r0 = r0,
        r1 = r1
      )
    }
  }
  # offsets count rows from the north, as a plain window read takes them
  # whichever way the file runs
  read_part <- function(p, out, scale, offset) {
    gdal_read_window(
      paths[[p$i]],
      band,
      p$sx + p$c0,
      p$sy + p$r0,
      p$c1 - p$c0,
      p$r1 - p$r0,
      nodata = nodata,
      out = out,
      scale = scale,
      offset = offset
    )
  }
  if (length(parts) == 1L) {
    p <- parts[[1L]]
    if (p$c0 == 0L && p$r0 == 0L && p$c1 == x_size && p$r1 == y_size) {
      return(read_part(p, out, scale, offset))
    }
  }
  nb <- length(band)
  n_px <- as.numeric(x_size) * y_size
  # f32 band planes, NaN where no source reaches
  buf <- .Call(
    "garry_paste_f32",
    NULL,
    raw(0),
    as.numeric(c(nb, x_size, y_size, 0, 0, 0, 0)),
    PACKAGE = "garry"
  )
  for (p in parts) {
    .Call(
      "garry_paste_f32",
      buf,
      read_part(p, "raw_f32", numeric(0), numeric(0)),
      as.numeric(c(nb, x_size, y_size, p$c0, p$r0, p$c1 - p$c0, p$r1 - p$r0)),
      PACKAGE = "garry"
    )
  }
  if (out == "raw_f32" && length(scale) == 0L) {
    gdim <- if (nb > 1L) c(nb, y_size, x_size) else c(y_size, x_size)
    return(structure(buf, gdim = as.integer(gdim), gdt = "f32"))
  }
  v <- readBin(buf, "numeric", n = n_px * nb, size = 4L)
  .gdal_finish_planes(v, nb, y_size, x_size, scale, offset, out)
}

# Run an idempotent read/fetch/warp thunk with task-scoped retries.
# GDAL's HTTP retry covers per-request failures inside one operation; a
# whole-operation failure (curl timeout, TLS reset, transient DNS, a
# failed open) is terminal without this. Attempts after the first back
# off exponentially (0.5 * 2^k s), jittered so a fleet tripping a
# provider limiter does not retry in lockstep. The final attempt's
# error propagates to the caller's read_fail contract.
.gdal_with_retry <- function(thunk, what) {
  retries <- max(0L, as.integer(garry_opt("read_retry")))
  for (k in seq_len(retries)) {
    res <- tryCatch(thunk(), error = function(e) e)
    if (!inherits(res, "error")) {
      return(res)
    }
    delay <- 0.5 * 2^(k - 1L) * stats::runif(1L, 0.75, 1.25)
    cli::cli_warn(paste0(
      "{what} failed (attempt {k} of {retries + 1L}), retrying in ",
      "{round(delay, 2)} s: {conditionMessage(res)}"
    ))
    Sys.sleep(delay)
  }
  thunk()
}

# Cap this process's GDAL block cache at `mb` MB. set_cache_max()
# applies whether or not GDAL has initialised its cache, unlike the
# GDAL_CACHEMAX config option, which is read once at first use.
# garry_daemons() broadcasts it to every pool.
.gdal_cache_cap <- function(mb) {
  gdalraster::set_cache_max(mb * 2^20)
  invisible(NULL)
}

#' Apply garry's default GDAL configuration for remote COG reads.
#'
#' Sets the GDAL config options garry's internal warp readers and
#' cloud-optimised remote reads want: HTTP multiplexing over HTTP/2,
#' automatic retries with backoff on transient HTTP errors plus request
#' timeouts (the cadence odc-stac uses), a capped block cache (GDAL
#' defaults to 5% of RAM *per process*, which many daemons would
#' multiply), single-range COG-header ingest, a skipped directory scan
#' and a vsicurl allowlist for fast remote opens (raster extensions,
#' plus the metadata and chunk keys of Zarr stores), and
#' permission to open MEM-driver datasets, which garry's internal warp
#' readers require. `garry_daemons()` calls this
#' on every read daemon automatically; call it yourself for host-side
#' discovery reads or when you drive `mirai::daemons()` directly. Each
#' option is set via `set_config_option`, so a value you set afterwards
#' wins.
#'
#' These are session-global GDAL settings. In particular
#' `GDAL_DISABLE_READDIR_ON_OPEN = EMPTY_DIR` speeds remote opens but can
#' hide sidecars (overviews, world files) for *local* multi-file reads in
#' the same session; pass `gdal_config = FALSE` to `garry_daemons()` to
#' skip it.
#'
#' @return Invisibly `NULL`.
#' @export
garry_gdal_config <- function() {
  sc <- gdalraster::set_config_option
  sc("GDAL_HTTP_MULTIPLEX", "YES")
  sc("GDAL_HTTP_VERSION", "2")
  sc("GDAL_HTTP_MAX_RETRY", "10")
  sc("GDAL_HTTP_RETRY_DELAY", "0.5")
  # GDAL_HTTP_RETRY_CODES stays unset: GDAL's default set is 429, 500 and
  # 502-504 plus curl timeouts and resets. GDAL matches an explicit list
  # by substring (GDAL 3.13), so "500" admits code 0 and every curl
  # failure, DNS included, retries with backoff for minutes.
  sc("GDAL_HTTP_TIMEOUT", "60")
  sc("GDAL_HTTP_CONNECTTIMEOUT", "10")
  sc("GDAL_CACHEMAX", as.character(as.integer(garry_opt("gdal_cachemax_mb"))))
  sc("GDAL_INGESTED_BYTES_AT_OPEN", "32768") # one range grabs the COG header
  sc("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  # Zarr's own keys (.zarr_allowed_ext); the list still refuses the
  # sidecar probes (.aux.xml, .ovr, .msk, ...) GDAL issues on every
  # remote open.
  sc(
    "CPL_VSIL_CURL_ALLOWED_EXTENSIONS",
    paste(c(".tif,.tiff,.TIF,.TIFF,.vrt,.jp2", .zarr_allowed_ext), collapse = ",")
  )
  sc("GDAL_MEM_ENABLE_OPEN", "YES") # >=3.10 gate for the direct warp
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# GTI (GDAL Raster Tile Index) support: the mosaic layer (decision D18).
# One datetime-attributed index serves every time slice via the FILTER
# open option; SORT_FIELD gives deterministic overlap resolution; mixed
# per-tile CRS is reprojected by the driver onto the pinned target grid.
# ---------------------------------------------------------------------------

#' Create a GTI tile index layer from a source table.
#'
#' `entries` must have a `location` column (paths / VSI URLs) and either
#' a `geom` column (WKT polygons in `crs`) or `xmin`/`ymin`/`xmax`/`ymax`
#' columns. All other columns become index fields (numeric -> Real,
#' otherwise String); a `datetime` column enables per-slice FILTERs and
#' SORT_FIELD ordering.
#'
#' @param entries data.frame describing one tile per row.
#' @param path Index path (".gti.gpkg" or ".gti.fgb" recommended).
#' @param crs CRS of the index geometries (any GDAL-interpretable form).
#' @param layer Layer name.
#' @return `path`, invisibly.
#' @seealso [gti_open_options()]
#' @export
gti_index_create <- function(entries, path, crs, layer = "index") {
  stopifnot(is.data.frame(entries), "location" %in% names(entries))
  has_geom <- "geom" %in% names(entries)
  if (!has_geom) {
    stopifnot(all(c("xmin", "ymin", "xmax", "ymax") %in% names(entries)))
  }

  field_cols <- setdiff(
    names(entries),
    c("geom", "xmin", "ymin", "xmax", "ymax")
  )
  defn <- gdalraster::ogr_def_layer(
    "POLYGON",
    srs = gdalraster::srs_to_wkt(crs)
  )
  for (col in field_cols) {
    defn[[col]] <- gdalraster::ogr_def_field(
      if (is.numeric(entries[[col]])) "OFTReal" else "OFTString"
    )
  }
  fmt <- if (grepl("\\.fgb$", path)) "FlatGeobuf" else "GPKG"
  if (!gdalraster::ogr_ds_create(fmt, path, layer = layer, layer_defn = defn)) {
    cli::cli_abort("failed to create GTI index dataset: {.path {path}}")
  }

  v <- methods::new(gdalraster::GDALVector, path, layer, read_only = FALSE)
  on.exit(v$close(), add = TRUE)
  for (i in seq_len(nrow(entries))) {
    ft <- as.list(entries[i, field_cols, drop = FALSE])
    ft$geom <- if (has_geom) {
      entries$geom[[i]]
    } else {
      gdalraster::bbox_to_wkt(as.numeric(
        entries[i, c("xmin", "ymin", "xmax", "ymax")]
      ))
    }
    if (!v$createFeature(ft)) {
      cli::cli_abort("failed to write index feature {i}")
    }
  }
  # Sidecar for the distributed scheduler's fetch/assemble split
  # (phase 12): the entries table lets the scheduler turn a remote
  # slice-mosaic read into per-item window fetches plus a local
  # reassembly (a location-rewritten copy of this index), without a
  # vector-read round-trip against the index file.
  saveRDS(
    list(entries = entries, crs = crs, layer = layer),
    paste0(path, ".meta.rds")
  )
  invisible(path)
}

# Record a GTI index's band count in its sidecar once a probe has seen it
# (the GTI driver infers it from the first tile): the fetch split writes
# failed-fetch placeholders with that many bands.
.gti_meta_set_bands <- function(path, nbands) {
  f <- paste0(path, ".meta.rds")
  if (!file.exists(f)) {
    return(invisible(path))
  }
  meta <- readRDS(f)
  meta$band_count <- as.integer(nbands)
  saveRDS(meta, f)
  invisible(path)
}

#' Copy one source's target-window bytes to a local file.
#'
#' The fetch half of the fetch/assemble split: a plain
#' `gdal_translate -srcwin` of the window intersecting `ext` (plus a
#' warp-kernel `margin` in source pixels), native dtype and blocks;
#' no warp, no mosaic on the remote path.
#'
#' @param location Source path/URL.
#' @param out_file Local destination GTiff.
#' @param ext,crs Target extent and CRS defining the window.
#' @param margin Source-pixel margin around the window.
#' @return `TRUE`, invisibly. Errors if the window is empty or the
#'   source unreadable.
#' @keywords internal
gdal_fetch_window <- function(
  location,
  out_file,
  ext,
  crs,
  margin = 8L,
  out_res = NULL
) {
  ds <- methods::new(gdalraster::GDALRaster, location, read_only = TRUE)
  gt <- ds$getGeoTransform()
  b <- gdalraster::transform_bounds(ext, crs, ds$getProjection())
  x0 <- max(0L, as.integer(floor((b[1] - gt[1]) / gt[2])) - margin)
  y0 <- max(0L, as.integer(floor((b[4] - gt[4]) / gt[6])) - margin)
  x1 <- min(
    ds$getRasterXSize(),
    as.integer(ceiling((b[3] - gt[1]) / gt[2])) + margin
  )
  y1 <- min(
    ds$getRasterYSize(),
    as.integer(ceiling((b[2] - gt[4]) / gt[6])) + margin
  )
  ds$close()
  stopifnot(x1 > x0, y1 > y0)
  w <- x1 - x0
  h <- y1 - y0
  # When the target grid is coarser than the source (a preview), decimate the
  # fetch to ~the target resolution: -outsize makes GDAL read the matching COG
  # overview, so only preview-resolution data crosses the network. Full-res
  # reads have a ratio ~ 1 and are untouched. The assemble warps this tile to
  # the exact grid, so an approximate factor is safe. The ratio is source
  # pixels over target pixels across the window, so it holds when the two
  # CRSs differ in units (a degree source onto a metre grid).
  osz <- character(0)
  if (!is.null(out_res)) {
    k <- w / ((ext[[3L]] - ext[[1L]]) / out_res)
    if (is.finite(k) && k > 1.5) {
      osz <- c(
        "-outsize",
        max(1L, as.integer(round(w / k))),
        max(1L, as.integer(round(h / k)))
      )
    }
  }
  # Uncompressed on purpose: the cache lives on tmpfs for one slice
  # assembly, and re-encoding (DEFLATE) costs more CPU across a
  # 20-plus-fetcher fleet than the bytes are worth (source blocks
  # still arrive compressed; only the local copy is raw).
  gdalraster::translate(
    location,
    out_file,
    cl_arg = c(
      "-srcwin",
      x0,
      y0,
      w,
      h,
      osz,
      "-co",
      "TILED=YES",
      "-co",
      "COMPRESS=NONE",
      "-q"
    )
  )
  invisible(TRUE)
}

#' Write a small all-nodata window (failed-fetch placeholder).
#'
#' Int16 with the sentinel when `nodata` is declared, else Byte 255
#' (the HLS QA fill convention): the local mosaic reads a hole where
#' the object went missing instead of erroring.
#'
#' @param out_file Destination GTiff.
#' @param ext,crs Window extent and CRS.
#' @param nodata Length-0 or length-1 sentinel.
#' @param nbands Band count: a multi-band mosaic reading band k from a
#'   placeholder with fewer bands fails ("has not enough bands"), so the
#'   placeholder matches the source's count.
#' @return `out_file`, invisibly.
#' @keywords internal
gdal_nodata_window <- function(
  out_file,
  ext,
  crs,
  nodata = numeric(0),
  nbands = 1L
) {
  has_nd <- length(nodata) == 1L
  nbands <- max(1L, as.integer(nbands))
  ds <- gdalraster::create(
    "GTiff",
    out_file,
    16,
    16,
    nbands,
    if (has_nd) "Int16" else "Byte",
    return_obj = TRUE
  )
  ds$setGeoTransform(c(
    ext[1],
    (ext[3] - ext[1]) / 16,
    0,
    ext[4],
    0,
    -(ext[4] - ext[2]) / 16
  ))
  ds$setProjection(gdalraster::srs_to_wkt(crs))
  fill <- if (has_nd) as.numeric(nodata) else 255
  for (b in seq_len(nbands)) {
    if (has_nd) {
      ds$setNoDataValue(b, fill)
    }
    ds$write(b, 0, 0, 16, 16, rep(fill, 256))
  }
  ds$close()
  invisible(out_file)
}

#' Build GTI open options pinning a target grid and slice filter.
#'
#' @param grid Optional `GridSpec`: pins SRS, resolution, and extent so
#'   every slice opens on exactly this grid.
#' @param filter Optional OGR SQL WHERE clause selecting index features
#'   (e.g. one datetime slice).
#' @param sort_field,sort_asc Optional deterministic overlap ordering
#'   (highest value on top when ascending).
#' @return Character vector of "KEY=VALUE" open options.
#' @seealso [gti_index_create()]
#' @export
gti_open_options <- function(
  grid = NULL,
  filter = NULL,
  sort_field = NULL,
  sort_asc = TRUE
) {
  num <- function(v) formatC(v, format = "g", digits = 17, width = 1)
  oo <- character(0)
  if (!is.null(grid)) {
    oo <- c(
      oo,
      paste0("SRS=", grid@crs),
      paste0("RESX=", num(grid@transform[2L])),
      paste0("RESY=", num(-grid@transform[6L])),
      paste0("MINX=", num(grid@extent[1L])),
      paste0("MINY=", num(grid@extent[2L])),
      paste0("MAXX=", num(grid@extent[3L])),
      paste0("MAXY=", num(grid@extent[4L]))
    )
  }
  if (!is.null(filter)) {
    oo <- c(oo, paste0("FILTER=", filter))
  }
  if (!is.null(sort_field)) {
    oo <- c(
      oo,
      paste0("SORT_FIELD=", sort_field),
      paste0("SORT_FIELD_ASC=", if (isTRUE(sort_asc)) "YES" else "NO")
    )
  }
  oo
}

# A GTI source read at a non-nearest resampling: the GTI driver takes the method
# from a `.gti` XML wrapper (it has no RESAMPLING open option), so wrap the index
# once beside itself (idempotent) and return that path. "near"/"nearest" and
# non-GTI paths pass through unchanged -- GTI already defaults to nearest. The
# wrapper composes with the RESX/RESY/FILTER/SORT open options as usual.
.gti_resampled_path <- function(path, resampling = "near") {
  if (
    length(path) != 1L ||
      length(resampling) != 1L ||
      resampling %in% c("", "near", "nearest") ||
      !startsWith(path, "GTI:")
  ) {
    return(path)
  }
  idx <- sub("^GTI:", "", path)
  wrap <- paste0(idx, ".gti")
  writeLines(
    .glue(
      "<GDALTileIndexDataset><IndexDataset>{idx}</IndexDataset>",
      "<IndexLayer>index</IndexLayer><Resampling>{resampling}</Resampling>",
      "</GDALTileIndexDataset>"
    ),
    wrap
  )
  wrap
}

# Read a vector source's bounding box in lon/lat (EPSG:4326). Lives in the
# adapter because it opens a GDALVector (decision D13); grid_from_src() calls it.
# Does GDAL identify `path` as a raster source? A header-only probe (no full
# open, no download for remote sources) that stays quiet on a non-raster, so
# callers can branch raster-vs-vector without spewing "not recognized" errors.
gdal_is_raster <- function(path) {
  drv <- tryCatch(
    gdalraster::identifyDriver(.gdal_href(path), raster = TRUE, vector = FALSE),
    error = function(e) ""
  )
  isTRUE(nzchar(drv))
}

gdal_vector_bbox_ll <- function(x) {
  vec <- methods::new(gdalraster::GDALVector, .gdal_href(x))
  on.exit(vec$close())
  bb <- as.numeric(vec$bbox())
  srs <- vec$getSpatialRef()
  if (nzchar(srs) && !crs_equal(srs, gdalraster::srs_to_wkt("EPSG:4326"))) {
    bb <- as.numeric(gdalraster::transform_bounds(bb, srs, "EPSG:4326"))
  }
  bb
}

# Number of raster bands in a source. In the adapter (decision D13); preview()
# uses it to choose default bands.
gdal_band_count <- function(path) {
  ds <- methods::new(gdalraster::GDALRaster, path)
  on.exit(ds$close())
  ds$getRasterCount()
}

