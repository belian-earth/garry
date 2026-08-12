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
  Byte = "u8", Int8 = "i8",
  UInt16 = "u16", Int16 = "i16",
  UInt32 = "u32", Int32 = "i32",
  UInt64 = "u64", Int64 = "i64",
  Float32 = "f32", Float64 = "f64"
)

# Dataset handle cache: open once per (path, open options) per process,
# LRU-capped. An open dataset is not free: a GTI/warped mosaic pins
# warper buffers, VSICURL caches and block-cache pages, so a daemon
# that reads many distinct slices grows without bound if handles are
# never closed (measured: multi-GB per daemon, machine OOM). Eviction
# closes the least-recently-used handle; reopening is milliseconds.
.gdal_cache <- new.env(parent = emptyenv())
.gdal_cache$handles <- list()   # named, insertion-ordered = LRU order

# http(s) URLs need the /vsicurl prefix so GDAL reads via HTTP range requests --
# metadata (header/IFD) and windowed pixel reads only -- instead of downloading
# the whole file. Idempotent: already-/vsicurl, /vsi*, GTI: and local paths pass
# through unchanged.
.gdal_href <- function(href) {
  if (grepl("^https?://", href)) paste0("/vsicurl/", href) else href
}

# Is a path a remote (network-backed) GDAL source?
.gdal_is_remote <- function(path) {
  grepl("^/vsi(curl|s3|gs|az|swift)|^https?://", path)
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
.gdal_quiet_remote <- function(code) {
  prev_rd <- gdalraster::get_config_option("GDAL_DISABLE_READDIR_ON_OPEN")
  prev_ib <- gdalraster::get_config_option("GDAL_INGESTED_BYTES_AT_OPEN")
  gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  gdalraster::set_config_option("GDAL_INGESTED_BYTES_AT_OPEN", "4194304")
  on.exit({
    gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", prev_rd)
    gdalraster::set_config_option("GDAL_INGESTED_BYTES_AT_OPEN", prev_ib)
  }, add = TRUE)
  force(code)
}

.gdal_handle <- function(path, open_options = character(0)) {
  path <- .gdal_href(path)                 # range-read remote COGs, never pull whole
  key <- paste(c(path, open_options), collapse = "\x1f")
  h <- .gdal_cache$handles[[key]]
  if (!is.null(h)) {
    .gdal_cache$handles[[key]] <- NULL          # move to MRU position
    .gdal_cache$handles[[key]] <- h
    return(h)
  }
  open_raw <- function() if (length(open_options) > 0L) {
    methods::new(gdalraster::GDALRaster, path, TRUE, open_options)
  } else {
    methods::new(gdalraster::GDALRaster, path, read_only = TRUE)
  }
  # Remote opens run under the scoped hygiene config (sidecar-probe
  # storm + serial IFD walk otherwise cost ~8 s each at typical RTT).
  open_ds <- function() {
    if (.gdal_is_remote(path)) .gdal_quiet_remote(open_raw()) else open_raw()
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
      if (grepl("Several coordinate operations", conditionMessage(w),
                fixed = TRUE))
        invokeRestart("muffleWarning")
    })
  cap <- garry_opt("handle_cache_max")
  while (length(.gdal_cache$handles) >= cap) {
    try(.gdal_cache$handles[[1L]]$close(), silent = TRUE)
    .gdal_cache$handles[[1L]] <- NULL
  }
  .gdal_cache$handles[[key]] <- h
  h
}

.gdal_handle_reset <- function() {
  for (h in .gdal_cache$handles) try(h$close(), silent = TRUE)
  .gdal_cache$handles <- list()
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
  if (is.null(dtype))
    cli::cli_abort("unsupported GDAL data type: {.val {dtype_name}}")

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

  block <- as.integer(ds$getBlockSize(band))   # (x, y)

  # Normalise to garry's north-up convention (D13). Most rasters are north-up
  # (gt[6] < 0), but some COGs (e.g. AEF embeddings) carry a positive y pixel
  # size (south-up); the footprint is identical, so take the corner min/max for
  # the extent and rebuild a north-up transform. Axis-aligned only: a rotated
  # geotransform cannot be an analysis grid.
  if (gt[3L] != 0 || gt[5L] != 0)
    cli::cli_abort("{.fn gdal_grid_spec}: rotated geotransform is not a valid analysis grid.")
  x1 <- gt[1L] + nx * gt[2L]
  y1 <- gt[4L] + ny * gt[6L]
  xmin <- min(gt[1L], x1); xmax <- max(gt[1L], x1)
  ymin <- min(gt[4L], y1); ymax <- max(gt[4L], y1)

  grid <- GridSpec(
    crs       = ds$getProjection(),
    transform = c(xmin, abs(gt[2L]), 0, ymax, 0, -abs(gt[6L])),
    extent    = c(xmin, ymin, xmax, ymax),
    dims      = c(x = nx, y = ny),
    dtype     = dtype
  )
  list(grid = grid, nodata = nodata, block_dim = block,
       scale = sc, offset = of)
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
#' @return With `out = "matrix"`: a numeric `y_size x x_size` matrix for
#'   a single band, or a `(band, y, x)` numeric array when `band` is a
#'   vector. With `out = "raw_f32"`: a raw row-major f32 payload (band
#'   planes contiguous when `band` is a vector).
#' @export
gdal_read_window <- function(path, band, x_off, y_off, x_size, y_size,
                             nodata = numeric(0),
                             open_options = character(0),
                             out = c("matrix", "raw_f32"),
                             scale = numeric(0), offset = numeric(0)) {
  out <- rlang::arg_match(out)
  # Raw-BSQ cube fast path: a garry raw cube (.bin + sibling
  # VRTRawRasterBand .vrt) reads via seek+readBin, skipping GDAL's
  # tile machinery AND this function's band-walk — measured 2026-08-02:
  # a 482 MB 73-band cube costs ~2.2 s through the GDAL path REGARDLESS
  # of compression (ZSTD == uncompressed == VRT-raw; the tile walk is
  # the cost, not the codec) vs 0.24 s raw. Anything non-conforming
  # (foreign VRTs, open options, out-of-range bands) falls through.
  if (length(open_options) == 0L) {
    info <- .raw_vrt_info(path)
    if (!is.null(info) && all(band >= 1L) && all(band <= info$nb))
      return(.raw_vrt_read(info, band, x_off, y_off, x_size, y_size,
                           nodata, out, scale, offset))
  }
  ds <- .gdal_handle(path, open_options)
  if (length(band) > 1L)
    return(.gdal_read_window_bands(ds, band, x_off, y_off, x_size, y_size,
                                   nodata, out, scale, offset))
  v <- ds$read(band, x_off, y_off, x_size, y_size, x_size, y_size)
  v <- as.numeric(v)
  if (length(nodata) == 1L) {
    v[!is.na(v) & v == nodata] <- NaN
  }
  v[is.na(v) & !is.nan(v)] <- NaN        # GDAL-side masked values
  if (length(scale) == 1L) v <- v * scale + offset
  # GDAL's buffer is already row-major: the raw f32 store payload (D19)
  # converts it directly, skipping the byrow transpose below.
  if (out == "raw_f32") return(.sv_from_vec(v, y_size, x_size))
  matrix(v, nrow = y_size, byrow = TRUE)
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
.gdal_read_window_bands <- function(ds, band, x_off, y_off, x_size, y_size,
                                    nodata, out, scale = numeric(0),
                                    offset = numeric(0)) {
  nb <- length(band)
  bs <- as.integer(ds$getBlockSize(band[[1L]]))       # (x, y)
  el_b <- tryCatch(.gdal_dtype_bytes(ds$getDataTypeName(band[[1L]])),
                   error = function(e) 8L)
  # Native bytes one image row of all bands pins in cache (strips span
  # the full raster width whatever the window; tiles at least the
  # window's columns).
  row_b <- max(bs[[1L]], x_size) * nb * el_b
  cache_b <- garry_opt("gdal_cachemax_mb") * 2^20
  by <- max(1L, bs[[2L]])
  slab <- max(by, as.integer(floor(cache_b * 0.5 / row_b) %/% by) * by)
  slab <- min(slab, y_size)

  n_px <- as.numeric(y_size) * x_size
  res <- if (out == "raw_f32") raw(4 * nb * n_px)
         else array(NA_real_, c(nb, y_size, x_size))
  r0 <- 0L
  while (r0 < y_size) {
    rows <- min(slab, y_size - r0)
    for (k in seq_len(nb)) {
      v <- as.numeric(ds$read(band[[k]], x_off, y_off + r0, x_size, rows,
                              x_size, rows))
      if (length(nodata) == 1L) v[!is.na(v) & v == nodata] <- NaN
      v[is.na(v) & !is.nan(v)] <- NaN
      if (length(scale) == 1L) v <- v * scale + offset
      if (out == "raw_f32") {
        p0 <- 4 * ((k - 1) * n_px + as.numeric(r0) * x_size)
        res[(p0 + 1):(p0 + 4 * length(v))] <- writeBin(v, raw(), size = 4L)
      } else {
        res[k, (r0 + 1L):(r0 + rows), ] <- matrix(v, nrow = rows, byrow = TRUE)
      }
    }
    r0 <- r0 + rows
  }
  if (out == "raw_f32")
    return(structure(res, gdim = as.integer(c(nb, y_size, x_size)),
                     gdt = "f32"))
  res
}

# Open an existing output for update (the writer daemon re-opens
# host-created files; GTiff is single-writer, so exactly one process
# holds this handle at a time).
gdal_open_update <- function(path) {
  methods::new(gdalraster::GDALRaster, path, read_only = FALSE)
}

# Create a raw-BSQ cube destination: a sparse zeroed .bin sized for the
# full cube plus the sibling VRT (georeference, dtype, nodata, band
# descriptions), returned open for update like any other output.
.raw_cube_create <- function(path, grid, n_bands, nodata = numeric(0),
                             band_names = NULL) {
  if (!grid@dtype %in% c("f32", "f64"))
    cli::cli_abort(paste0(
      "raw cubes hold f32/f64 only (got {.val {grid@dtype}}); ",
      "write a .tif for integer outputs"))
  bytes <- if (identical(grid@dtype, "f32")) 4L else 8L
  nx <- grid@dims[["x"]]; ny <- grid@dims[["y"]]
  bin <- sub("\\.vrt$", ".bin", path, ignore.case = TRUE)
  total <- as.numeric(nx) * ny * n_bands * bytes
  con <- file(bin, "wb")
  seek(con, total - 1)                 # sparse allocation
  writeBin(raw(1L), con)
  close(con)
  gt_csv <- paste(formatC(grid@transform, format = "g", digits = 17, width = 1),
                  collapse = ", ")
  xml <- .raw_bsq_vrt_xml(
    basename(bin), nx, ny, gt_csv, grid@crs,
    if (bytes == 4L) "Float32" else "Float64", n_bands,
    nodata = if (length(nodata) == 1L) nodata else NULL,
    descriptions = band_names)
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
  if (!grepl("\\.vrt$", dst_vrt, ignore.case = TRUE))
    cli::cli_abort("{.arg dst_vrt} must end in .vrt")
  meta <- gdal_grid_spec(src)
  ds <- methods::new(gdalraster::GDALRaster, src)
  nb <- ds$getRasterCount()
  dtn <- ds$getDataTypeName(1L)
  descs <- vapply(seq_len(nb), function(b) ds$getDescription(b),
                  character(1))
  ds$close()
  grid <- meta$grid
  if (identical(dtn, "Float64")) grid <- .grid_retype(grid, "f64")
  nx <- grid@dims[["x"]]; ny <- grid@dims[["y"]]
  bytes <- if (identical(grid@dtype, "f64")) 8L else 4L
  bin <- sub("\\.vrt$", ".bin", dst_vrt, ignore.case = TRUE)
  con <- file(bin, "wb")
  # band-major planes: per band, stream row slabs
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
  close(con)
  gt_csv <- paste(formatC(grid@transform, format = "g", digits = 17, width = 1),
                  collapse = ", ")
  xml <- .raw_bsq_vrt_xml(
    basename(bin), nx, ny, gt_csv, grid@crs,
    if (bytes == 4L) "Float32" else "Float64", nb,
    nodata = if (length(meta$nodata) == 1L) meta$nodata else NULL,
    descriptions = descs)   # QA bands are found BY DESCRIPTION downstream
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
  if (!grepl("\\.vrt$", path, ignore.case = TRUE)) return(NULL)
  key <- paste0(path, "\x1f", as.numeric(file.mtime(path)))
  hit <- .raw_vrt_cache[[key]]
  if (!is.null(hit)) return(if (isFALSE(hit)) NULL else hit)
  info <- tryCatch(.raw_vrt_parse(path), error = function(e) NULL)
  .raw_vrt_cache[[key]] <- info %||% FALSE
  info
}

# Bytes per sample for a GDAL data-type name.
.gdal_dtype_bytes <- function(dt) {
  b <- c(Byte = 1L, Int8 = 1L, UInt16 = 2L, Int16 = 2L, UInt32 = 4L,
         Int32 = 4L, UInt64 = 8L, Int64 = 8L, Float32 = 4L, Float64 = 8L)[[dt]]
  if (is.null(b)) cli::cli_abort("Unsupported buffer dtype {.val {dt}}.")
  b
}

# Build a VRTRawRasterBand dataset XML over a raw band-sequential (BSQ) buffer, so
# GDAL reads it with zero decode. Band b's plane starts at (b-1) * nx * ny * bytes;
# pixels are row-major within it. `src` is the .bin basename, referenced as a
# relativeToVRT sibling (the VRT must be written beside it): GDAL refuses a raw
# band pointing at an arbitrary absolute path unless the source is a sibling/child
# of the VRT (or GDAL_VRT_RAWRASTERBAND_ALLOWED_SOURCE is set), which this
# satisfies rather than loosening the global config.
.raw_bsq_vrt_xml <- function(src, nx, ny, gt_csv, wkt, dtype, nbands,
                             nodata = NULL, descriptions = NULL) {
  bytes <- .gdal_dtype_bytes(dtype)
  plane <- as.numeric(nx) * as.numeric(ny) * bytes
  ndxml <- if (!is.null(nodata))
    .glue("\n    <NoDataValue>{format(nodata, scientific = FALSE)}",
          "</NoDataValue>") else ""
  bands_xml <- vapply(seq_len(nbands), function(b) {
    desc <- if (!is.null(descriptions) && b <= length(descriptions) &&
                nzchar(descriptions[[b]]))
      .glue("\n    <Description>{descriptions[[b]]}</Description>")
    else ""
    .glue(
      '  <VRTRasterBand dataType="{dtype}" band="{b}" ',
      'subClass="VRTRawRasterBand">{desc}',
      '\n    <SourceFilename relativeToVRT="1">{src}</SourceFilename>',
      "\n    <ImageOffset>",
      "{formatC((b - 1) * plane, format = 'f', digits = 0)}</ImageOffset>",
      "\n    <PixelOffset>{bytes}</PixelOffset>",
      "\n    <LineOffset>{as.integer(nx * bytes)}</LineOffset>{ndxml}",
      "\n  </VRTRasterBand>")
  }, "")
  .glue('<VRTDataset rasterXSize="{nx}" rasterYSize="{ny}">',
        "\n  <SRS>{wkt}</SRS>\n  <GeoTransform>{gt_csv}</GeoTransform>",
        "\n{paste(bands_xml, collapse = '\n')}\n</VRTDataset>")
}

# Strict recognition of the .raw_bsq_vrt_xml shape: every band a
# VRTRawRasterBand over ONE relativeToVRT sibling, uniform Float32 or
# Float64, exact BSQ strides, bin present at the implied size. Any
# deviation returns NULL (the GDAL path handles it).
.raw_vrt_parse <- function(path) {
  xml <- paste(readLines(path, warn = FALSE), collapse = "\n")
  if (!grepl('subClass="VRTRawRasterBand"', xml, fixed = TRUE)) return(NULL)
  hdr <- regmatches(xml, regexec(
    'rasterXSize="(\\d+)"[^>]*rasterYSize="(\\d+)"', xml))[[1L]]
  if (length(hdr) < 3L) return(NULL)
  nx <- as.integer(hdr[[2L]]); ny <- as.integer(hdr[[3L]])
  bands <- regmatches(xml, gregexpr(
    '(?s)<VRTRasterBand.*?</VRTRasterBand>', xml, perl = TRUE))[[1L]]
  if (!length(bands)) return(NULL)
  g1 <- function(b, re) {
    m <- regmatches(b, regexec(re, b, perl = TRUE))[[1L]]
    if (length(m) < 2L) NA_character_ else m[[2L]]
  }
  dt <- vapply(bands, g1, "", 'dataType="([^"]+)"', USE.NAMES = FALSE)
  if (length(unique(dt)) != 1L || !dt[[1L]] %in% c("Float32", "Float64"))
    return(NULL)
  if (!all(grepl('subClass="VRTRawRasterBand"', bands, fixed = TRUE)))
    return(NULL)
  src <- vapply(bands, g1, "",
                '<SourceFilename relativeToVRT="1">([^<]+)</SourceFilename>',
                USE.NAMES = FALSE)
  if (anyNA(src) || length(unique(src)) != 1L) return(NULL)
  bno <- as.integer(vapply(bands, g1, "", ' band="(\\d+)"',
                           USE.NAMES = FALSE))
  ioff <- as.numeric(vapply(bands, g1, "",
                            "<ImageOffset>(\\d+)</ImageOffset>",
                            USE.NAMES = FALSE))
  poff <- as.integer(vapply(bands, g1, "",
                            "<PixelOffset>(\\d+)</PixelOffset>",
                            USE.NAMES = FALSE))
  loff <- as.integer(vapply(bands, g1, "",
                            "<LineOffset>(\\d+)</LineOffset>",
                            USE.NAMES = FALSE))
  nd <- suppressWarnings(as.numeric(vapply(bands, g1, "",
    "<NoDataValue>([^<]+)</NoDataValue>", USE.NAMES = FALSE)))
  bytes <- if (dt[[1L]] == "Float32") 4L else 8L
  plane <- as.numeric(nx) * ny * bytes
  nb <- length(bands)
  ok <- !anyNA(bno) && identical(bno, seq_len(nb)) &&
    !anyNA(ioff) && all(ioff == (bno - 1) * plane) &&
    all(poff == bytes) && all(loff == nx * bytes)
  if (!isTRUE(ok)) return(NULL)
  bin <- file.path(dirname(path), src[[1L]])
  if (!file.exists(bin) || file.size(bin) < nb * plane) return(NULL)
  list(bin = bin, nx = nx, ny = ny, nb = nb, bytes = bytes,
       dtype = if (bytes == 4L) "f32" else "f64",
       nodata = if (length(unique(nd)) == 1L) nd[[1L]] else NA_real_)
}

# The fast read: per band, seek to the window's first full-width row,
# read y_size rows in one gulp, column-subset when the window is
# narrower than the raster. Output shapes/dtypes/nodata semantics are
# byte-identical to the GDAL path (the equivalence test holds them
# together).
.raw_vrt_read <- function(info, band, x_off, y_off, x_size, y_size,
                          nodata, out, scale = numeric(0),
                          offset = numeric(0)) {
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
  if (out == "raw_f32" && es == 4L && length(nodata) != 1L &&
      length(scale) != 1L) {
    idx <- if (!full) {
      within <- (x_off * 4L + 1L):((x_off + x_size) * 4L)
      rep((seq_len(y_size) - 1L) * (nx * 4L), each = length(within)) +
        within
    }
    parts <- vector("list", nb)
    for (k in seq_len(nb)) {
      seek(con, ((band[[k]] - 1) * as.numeric(nx) * info$ny +
                   as.numeric(y_off) * nx) * 4)
      p <- readBin(con, "raw", n = as.numeric(y_size) * nx * 4)
      parts[[k]] <- if (full) p else p[idx]
    }
    v <- if (nb == 1L) parts[[1L]] else do.call(c, parts)
    if (nb == 1L)
      return(structure(v, gdim = c(y_size, x_size), gdt = "f32"))
    return(structure(v, gdim = as.integer(c(nb, y_size, x_size)),
                     gdt = "f32"))
  }
  # numeric path (matrix out, f64, sentinel mapping, partial width)
  res <- if (nb > 1L && out != "raw_f32")
    array(NA_real_, c(nb, y_size, x_size)) else NULL
  raws <- if (out == "raw_f32") vector("list", nb)
  single <- NULL
  for (k in seq_len(nb)) {
    seek(con, ((band[[k]] - 1) * as.numeric(nx) * info$ny +
                 as.numeric(y_off) * nx) * es)
    v <- readBin(con, "numeric", n = as.numeric(y_size) * nx, size = es)
    if (!full) {
      # row-major rows: as an (nx x y_size) matrix each COLUMN is one
      # image row; subsetting its rows takes the window's columns, and
      # flattening back is row-major again
      v <- as.numeric(matrix(v, nrow = nx)[
        (x_off + 1L):(x_off + x_size), , drop = FALSE])
    }
    if (length(nodata) == 1L) v[!is.na(v) & v == nodata] <- NaN
    v[is.na(v) & !is.nan(v)] <- NaN
    if (length(scale) == 1L) v <- v * scale + offset
    if (out == "raw_f32") raws[[k]] <- writeBin(v, raw(), size = 4L)
    else if (nb > 1L) res[k, , ] <- matrix(v, nrow = y_size, byrow = TRUE)
    else single <- v
  }
  if (out == "raw_f32") {
    v <- if (nb == 1L) raws[[1L]] else do.call(c, raws)
    if (nb == 1L)
      return(structure(v, gdim = c(y_size, x_size), gdt = "f32"))
    return(structure(v, gdim = as.integer(c(nb, y_size, x_size)),
                     gdt = "f32"))
  }
  if (nb > 1L) return(res)
  matrix(single, nrow = y_size, byrow = TRUE)
}

# Reverse dtype map for writing.
.gdal_dtype_rev <- c(
  u8 = "Byte", i8 = "Int8",
  u16 = "UInt16", i16 = "Int16",
  u32 = "UInt32", i32 = "Int32",
  u64 = "UInt64", i64 = "Int64",
  f32 = "Float32", f64 = "Float64"
)

#' Build a warped VRT of a source onto an exact target grid.
#'
#' Delegates every pixel of cross-CRS math to the GDAL warper:
#' `-te`/`-ts` pin the output grid exactly to `target_grid`.
#' Float targets without a source nodata get `-dstnodata nan` so area
#' outside the source footprint reads as NaN, not 0.
#'
#' @param src_path Source path/VSI URL.
#' @param band 1-based source band (the VRT has this single band).
#' @param target_grid `GridSpec` to warp onto.
#' @param resampling GDAL resampling method name.
#' @param src_nodata Source sentinel (length 0 or 1), from the SourceNode.
#' @return Path to the VRT file (in `tempdir()`).
#' @export
gdal_warp_vrt <- function(src_path, band, target_grid, resampling,
                          src_nodata = numeric(0)) {
  src_path <- .gdal_href(src_path)   # bare https would pull the whole file
  vrt <- tempfile(fileext = ".vrt")
  num <- function(v) formatC(v, format = "g", digits = 17, width = 1)
  args <- c("-of", "VRT",
            "-te", num(target_grid@extent[1L]), num(target_grid@extent[2L]),
                   num(target_grid@extent[3L]), num(target_grid@extent[4L]),
            "-ts", target_grid@dims[["x"]], target_grid@dims[["y"]],
            "-r", resampling,
            "-b", band,
            "-et", "0")   # exact transformer: correctness over warp speed
  if (length(src_nodata) == 0L &&
      .dtype_family(target_grid@dtype) == "float") {
    args <- c(args, "-dstnodata", "nan")
  }
  do_warp <- function() gdalraster::warp(src_path, vrt,
                                         t_srs = target_grid@crs,
                                         cl_arg = args, quiet = TRUE)
  # warp opens the source internally (bypassing .gdal_handle), so it
  # needs the same remote-open hygiene scoping
  ok <- if (.gdal_is_remote(src_path)) .gdal_quiet_remote(do_warp())
        else do_warp()
  if (!isTRUE(ok)) cli::cli_abort("gdalwarp to VRT failed for {.path {src_path}}")
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
#' @export
gdal_version_num <- function() {
  n <- suppressWarnings(as.integer(gdalraster::gdal_version()[[2L]]))
  if (length(n) != 1L || is.na(n)) NA_integer_ else n
}

#' GDAL runtime version as a human string (adapter).
#' @return Character, e.g. `"GDAL 3.9.0, released ..."`.
#' @keywords internal
#' @export
gdal_version_str <- function() gdalraster::gdal_version()[[1L]]

#' Mosaic already-grid-aligned rasters into a VRT (adapter).
#'
#' `gdalbuildvrt` of same-grid single-band rasters: overlapping pixels take the
#' LAST input, so pass `files` in ascending priority (latest datetime last, to
#' match the highest-on-top overlap rule). Used to assemble multi-tile
#' mosaics (e.g. the file form of [lazy_dataset()]).
#'
#' @param dst Output VRT path.
#' @param files Grid-aligned input rasters, low-to-high priority.
#' @return `dst`.
#' @keywords internal
gdal_mosaic_vrt <- function(dst, files, te = NULL, ts = NULL,
                            vrtnodata = NULL) {
  args <- character(0)
  if (!is.null(te)) {
    te <- as.numeric(te)
    if (is.null(ts)) cli::cli_abort("`te` requires `ts`.")
    ts <- as.numeric(ts)
    tr <- c((te[[3L]] - te[[1L]]) / ts[[1L]],
            (te[[4L]] - te[[2L]]) / ts[[2L]])
    args <- c("-te", formatC(te, format = "g", digits = 16, width = 1),
              "-tr", formatC(tr, format = "g", digits = 16, width = 1))
  }
  if (length(vrtnodata))
    args <- c(args, "-vrtnodata",
              formatC(vrtnodata[[1L]], format = "g", digits = 16, width = 1))
  do_build <- function() gdalraster::buildVRT(
    dst, files, cl_arg = if (length(args)) args else NULL, quiet = TRUE)
  if (any(.gdal_is_remote(files))) .gdal_quiet_remote(do_build())
  else do_build()
  if (!file.exists(dst)) cli::cli_abort("buildVRT mosaic failed.")
  dst
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
#' @export
gdal_create_output <- function(path, grid, nodata = numeric(0),
                               options = NULL,
                               band_names = NULL, dtype = NULL,
                               scale = numeric(0), offset = numeric(0)) {
  if (!is.null(dtype)) grid <- .grid_retype(grid, dtype)
  dt <- .gdal_dtype_rev[[grid@dtype]]
  if (is.null(dt)) cli::cli_abort("cannot write dtype: {.val {grid@dtype}}")
  outer <- grid@dims[!names(grid@dims) %in% c("x", "y")]
  if (length(outer) > 1L)
    cli::cli_abort(
      "cannot write a grid with more than one non-spatial dim ({names(outer)})")
  n_bands <- if (length(outer) == 1L) as.integer(outer[[1L]]) else 1L
  # A ".vrt" destination writes a raw-BSQ cube (.bin + sibling VRT)
  # instead of a GTiff: the intermediate format whose reads bypass the
  # tile machinery (~9x on multi-band windows). Update-writes go
  # through the VRT, so the streamed writer daemon works unchanged.
  if (grepl("\\.vrt$", path, ignore.case = TRUE))
    return(.raw_cube_create(path, grid, n_bands, nodata, band_names))
  if (is.null(options)) {
    # NUM_THREADS parallelises per-tile DEFLATE inside the (single)
    # writer daemon: the streamed-write flush of a 64-band AEF cube was
    # a 57 s single-threaded backlog after the drain (2026-08-12).
    # Tiles compress independently, so output bytes are unchanged.
    options <- c("COMPRESS=DEFLATE", "TILED=YES",
                 "BLOCKXSIZE=256", "BLOCKYSIZE=256", "BIGTIFF=IF_SAFER",
                 "NUM_THREADS=ALL_CPUS")
    if (n_bands > 1L) options <- c(options, "INTERLEAVE=BAND")
  }
  ds <- gdalraster::create("GTiff", path,
                           grid@dims[["x"]], grid@dims[["y"]], n_bands, dt,
                           options = options, return_obj = TRUE)
  ds$setGeoTransform(grid@transform)
  ds$setProjection(grid@crs)
  if (length(nodata) == 1L)
    for (b in seq_len(n_bands)) ds$setNoDataValue(b, nodata)
  if (length(scale) == 1L)
    for (b in seq_len(n_bands)) {
      ds$setScale(b, scale)
      ds$setOffset(b, if (length(offset) == 1L) offset else 0)
    }
  if (length(band_names) > 0L)
    for (b in seq_len(min(n_bands, length(band_names))))
      if (nzchar(band_names[[b]])) ds$setDescription(b, band_names[[b]])
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
#' @param scale,offset Optional quantization affine: values are stored as
#'   `round((v - offset) / scale)` (round-half-even) BEFORE NaN demotes to
#'   `nodata`, so the sentinel lives in stored units and must sit outside
#'   the quantized value range.
#' @return Invisibly, `NULL`.
#' @export
gdal_write_window <- function(ds, x_off, y_off, m, dtype,
                              nodata = numeric(0), band = 1L,
                              scale = numeric(0), offset = numeric(0)) {
  if (.sv_is(m)) {
    # Raw store payloads are already in GDAL's row-major write order.
    d <- .sv_dim(m)
    v <- .sv_to_vec(m)
    nr <- d[[1L]]
    nc <- d[[2L]]
  } else {
    nr <- nrow(m)
    nc <- ncol(m)
    v <- as.numeric(t(m))
  }
  if (length(scale) == 1L)
    v <- round((v - (if (length(offset) == 1L) offset else 0)) / scale)
  if (length(nodata) == 1L) {
    v[is.na(v)] <- nodata
  } else if (anyNA(v) && .dtype_family(dtype) != "float") {
    cli::cli_abort(paste0(
      "result contains nodata (NaN) but no {.arg nodata} sentinel was ",
      "given for integer output dtype {.val {dtype}}"))
  }
  ds$write(as.integer(band), x_off, y_off, nc, nr, v)
  invisible(NULL)
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
gdal_warp_to_buffer <- function(buf, nx, ny, gtstr, wkt, srcs, srcnodata = NULL,
                                resampling = "near") {
  gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")   # >=3.10 gate
  # `buf` is a RAW f32 byte vector (the raw-f32 store, D19-D21). The public
  # gdalraster::rvector_to_MEM() infers the band type from the R vector type
  # (integer/double/complex) and cannot expose raw bytes as Float32, so the
  # pure-R way to zero-copy-warp into an f32 buffer is the data pointer plus an
  # explicit DATATYPE=Float32 MEM DSN. get_data_ptr() is exported from
  # gdalraster 2.6.1.9001 (previously an internal resolved at runtime), hence
  # the Remotes pin on the dev version.
  ptr <- gdalraster::get_data_ptr(buf)
  dsn <- .glue(
    "MEM:::DATAPOINTER={ptr},PIXELS={nx},LINES={ny},BANDS=1,",
    "DATATYPE=Float32,GEOTRANSFORM={gtstr}")
  o <- methods::new(gdalraster::GDALRaster, dsn, FALSE)
  o$setProjection(wkt)
  cl <- c("-r", resampling, "-q", "-dstnodata", "nan")
  if (length(srcnodata) == 1L)
    cl <- c(cl, "-srcnodata", format(srcnodata, scientific = FALSE))
  gdalraster::warp(srcs, o, "", cl_arg = cl)
  o$close()
  buf
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
    if (!inherits(res, "error")) return(res)
    delay <- 0.5 * 2^(k - 1L) * stats::runif(1L, 0.75, 1.25)
    cli::cli_warn(paste0(
      "{what} failed (attempt {k} of {retries + 1L}), retrying in ",
      "{round(delay, 2)} s: {conditionMessage(res)}"))
    Sys.sleep(delay)
  }
  thunk()
}

#' Apply garry's default GDAL configuration for remote COG reads.
#'
#' Sets the GDAL config options garry's internal warp readers and
#' cloud-optimised remote reads want: HTTP multiplexing over HTTP/2,
#' automatic retries with backoff on transient HTTP errors plus request
#' timeouts (the cadence odc-stac uses), a capped block cache (GDAL
#' defaults to 5% of RAM *per process*, which many daemons would
#' multiply), single-range COG-header ingest, a skipped directory scan
#' and a raster-extension vsicurl allowlist for fast remote opens, and
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
  sc("GDAL_HTTP_RETRY_CODES", "429,500,502,503,504")
  sc("GDAL_HTTP_TIMEOUT", "60")
  sc("GDAL_HTTP_CONNECTTIMEOUT", "10")
  sc("GDAL_CACHEMAX", as.character(as.integer(garry_opt("gdal_cachemax_mb"))))
  sc("GDAL_INGESTED_BYTES_AT_OPEN", "32768")       # one range grabs the COG header
  sc("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  sc("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".tif,.tiff,.TIF,.TIFF,.vrt,.jp2")
  sc("GDAL_MEM_ENABLE_OPEN", "YES")                # >=3.10 gate for the direct warp
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
  if (!has_geom)
    stopifnot(all(c("xmin", "ymin", "xmax", "ymax") %in% names(entries)))

  field_cols <- setdiff(names(entries),
                        c("geom", "xmin", "ymin", "xmax", "ymax"))
  defn <- gdalraster::ogr_def_layer("POLYGON",
                                    srs = gdalraster::srs_to_wkt(crs))
  for (col in field_cols) {
    defn[[col]] <- gdalraster::ogr_def_field(
      if (is.numeric(entries[[col]])) "OFTReal" else "OFTString")
  }
  fmt <- if (grepl("\\.fgb$", path)) "FlatGeobuf" else "GPKG"
  if (!gdalraster::ogr_ds_create(fmt, path, layer = layer,
                                 layer_defn = defn))
    cli::cli_abort("failed to create GTI index dataset: {.path {path}}")

  v <- methods::new(gdalraster::GDALVector, path, layer, read_only = FALSE)
  on.exit(v$close(), add = TRUE)
  for (i in seq_len(nrow(entries))) {
    ft <- as.list(entries[i, field_cols, drop = FALSE])
    ft$geom <- if (has_geom) entries$geom[[i]] else {
      gdalraster::bbox_to_wkt(as.numeric(
        entries[i, c("xmin", "ymin", "xmax", "ymax")]))
    }
    if (!v$createFeature(ft))
      cli::cli_abort("failed to write index feature {i}")
  }
  # Sidecar for the distributed scheduler's fetch/assemble split
  # (phase 12): the entries table lets the scheduler turn a remote
  # slice-mosaic read into per-item window fetches plus a local
  # reassembly (a location-rewritten copy of this index), without a
  # vector-read round-trip against the index file.
  saveRDS(list(entries = entries, crs = crs, layer = layer),
          paste0(path, ".meta.rds"))
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
gdal_fetch_window <- function(location, out_file, ext, crs,
                              margin = 8L, out_res = NULL) {
  ds <- methods::new(gdalraster::GDALRaster, location, read_only = TRUE)
  gt <- ds$getGeoTransform()
  b <- gdalraster::transform_bounds(ext, crs, ds$getProjection())
  x0 <- max(0L, as.integer(floor((b[1] - gt[1]) / gt[2])) - margin)
  y0 <- max(0L, as.integer(floor((b[4] - gt[4]) / gt[6])) - margin)
  x1 <- min(ds$getRasterXSize(),
            as.integer(ceiling((b[3] - gt[1]) / gt[2])) + margin)
  y1 <- min(ds$getRasterYSize(),
            as.integer(ceiling((b[2] - gt[4]) / gt[6])) + margin)
  ds$close()
  stopifnot(x1 > x0, y1 > y0)
  w <- x1 - x0; h <- y1 - y0
  # When the target grid is coarser than the source (a preview), decimate the
  # fetch to ~the target resolution: -outsize makes GDAL read the matching COG
  # overview, so only preview-resolution data crosses the network. Full-res
  # reads have out_res ~ the native res (ratio ~ 1) and are untouched. The
  # assemble warps this tile to the exact grid, so an approximate factor is safe
  # (out_res and the source res are both assumed metric).
  osz <- character(0)
  if (!is.null(out_res)) {
    k <- out_res / abs(gt[2L])
    if (is.finite(k) && k > 1.5)
      osz <- c("-outsize", max(1L, as.integer(round(w / k))),
                           max(1L, as.integer(round(h / k))))
  }
  # Uncompressed on purpose: the cache lives on tmpfs for one slice
  # assembly, and re-encoding (DEFLATE) costs more CPU across a
  # 20-plus-fetcher fleet than the bytes are worth (source blocks
  # still arrive compressed; only the local copy is raw).
  gdalraster::translate(
    location, out_file,
    cl_arg = c("-srcwin", x0, y0, w, h, osz,
               "-co", "TILED=YES", "-co", "COMPRESS=NONE", "-q"))
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
#' @return `out_file`, invisibly.
#' @keywords internal
gdal_nodata_window <- function(out_file, ext, crs,
                               nodata = numeric(0)) {
  has_nd <- length(nodata) == 1L
  ds <- gdalraster::create("GTiff", out_file, 16, 16, 1,
                           if (has_nd) "Int16" else "Byte",
                           return_obj = TRUE)
  ds$setGeoTransform(c(ext[1], (ext[3] - ext[1]) / 16, 0,
                       ext[4], 0, -(ext[4] - ext[2]) / 16))
  ds$setProjection(gdalraster::srs_to_wkt(crs))
  fill <- if (has_nd) as.numeric(nodata) else 255
  if (has_nd) ds$setNoDataValue(1, fill)
  ds$write(1, 0, 0, 16, 16, rep(fill, 256))
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
gti_open_options <- function(grid = NULL, filter = NULL,
                             sort_field = NULL, sort_asc = TRUE) {
  num <- function(v) formatC(v, format = "g", digits = 17, width = 1)
  oo <- character(0)
  if (!is.null(grid)) {
    oo <- c(oo,
            paste0("SRS=", grid@crs),
            paste0("RESX=", num(grid@transform[2L])),
            paste0("RESY=", num(-grid@transform[6L])),
            paste0("MINX=", num(grid@extent[1L])),
            paste0("MINY=", num(grid@extent[2L])),
            paste0("MAXX=", num(grid@extent[3L])),
            paste0("MAXY=", num(grid@extent[4L])))
  }
  if (!is.null(filter)) oo <- c(oo, paste0("FILTER=", filter))
  if (!is.null(sort_field)) {
    oo <- c(oo, paste0("SORT_FIELD=", sort_field),
            paste0("SORT_FIELD_ASC=", if (isTRUE(sort_asc)) "YES" else "NO"))
  }
  oo
}

# A GTI source read at a non-nearest resampling: the GTI driver takes the method
# from a `.gti` XML wrapper (it has no RESAMPLING open option), so wrap the index
# once beside itself (idempotent) and return that path. "near"/"nearest" and
# non-GTI paths pass through unchanged -- GTI already defaults to nearest. The
# wrapper composes with the RESX/RESY/FILTER/SORT open options as usual.
.gti_resampled_path <- function(path, resampling = "near") {
  if (length(resampling) != 1L || resampling %in% c("", "near", "nearest") ||
      !startsWith(path, "GTI:")) return(path)
  idx  <- sub("^GTI:", "", path)
  wrap <- paste0(idx, ".gti")
  writeLines(.glue(
    "<GDALTileIndexDataset><IndexDataset>{idx}</IndexDataset>",
    "<IndexLayer>index</IndexLayer><Resampling>{resampling}</Resampling>",
    "</GDALTileIndexDataset>"), wrap)
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
    error = function(e) "")
  isTRUE(nzchar(drv))
}

gdal_vector_bbox_ll <- function(x) {
  vec <- methods::new(gdalraster::GDALVector, .gdal_href(x))
  on.exit(vec$close())
  bb  <- as.numeric(vec$bbox())
  srs <- vec$getSpatialRef()
  if (nzchar(srs) && !crs_equal(srs, gdalraster::srs_to_wkt("EPSG:4326")))
    bb <- as.numeric(gdalraster::transform_bounds(bb, srs, "EPSG:4326"))
  bb
}

# Number of raster bands in a source. In the adapter (decision D13); preview()
# uses it to choose default bands.
gdal_band_count <- function(path) {
  ds <- methods::new(gdalraster::GDALRaster, path)
  on.exit(ds$close())
  ds$getRasterCount()
}


# Toggle GDAL error-logging to R off for a code block (thread-safety:
# gdalraster's R-callback handler aborts the process when a GDAL worker
# thread warns). Lives here per the gdalraster quarantine.
.gdal_log_errors_off <- function(code) {
  prev <- gdalraster::get_config_option("CPL_LOG_ERRORS")
  gdalraster::set_config_option("CPL_LOG_ERRORS", "OFF")
  on.exit(gdalraster::set_config_option("CPL_LOG_ERRORS", prev), add = TRUE)
  force(code)
}
