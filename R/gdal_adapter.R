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

.gdal_handle <- function(path, open_options = character(0)) {
  key <- paste(c(path, open_options), collapse = "\x1f")
  h <- .gdal_cache$handles[[key]]
  if (!is.null(h)) {
    .gdal_cache$handles[[key]] <- NULL          # move to MRU position
    .gdal_cache$handles[[key]] <- h
    return(h)
  }
  open_ds <- function() if (length(open_options) > 0L) {
    methods::new(gdalraster::GDALRaster, path, TRUE, open_options)
  } else {
    methods::new(gdalraster::GDALRaster, path, read_only = TRUE)
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
#'   `block_dim` (integer length 2, x then y).
#' @export
gdal_grid_spec <- function(path, band = 1L, open_options = character(0)) {
  ds <- .gdal_handle(path, open_options)
  gt <- ds$getGeoTransform()
  nx <- ds$getRasterXSize()
  ny <- ds$getRasterYSize()

  dtype_name <- ds$getDataTypeName(band)
  dtype <- .gdal_dtype_map[[dtype_name]]
  if (is.null(dtype))
    stop("unsupported GDAL data type: ", dtype_name)

  nodata <- ds$getNoDataValue(band)
  nodata <- if (is.na(nodata)) numeric(0) else as.numeric(nodata)

  block <- as.integer(ds$getBlockSize(band))   # (x, y)

  grid <- GridSpec(
    crs       = ds$getProjection(),
    transform = gt,
    extent    = c(gt[1L],                 # xmin
                  gt[4L] + ny * gt[6L],   # ymin
                  gt[1L] + nx * gt[2L],   # xmax
                  gt[4L]),                # ymax
    dims      = c(x = nx, y = ny),
    dtype     = dtype
  )
  list(grid = grid, nodata = nodata, block_dim = block)
}

#' Read a window from a GDAL source as a garry-oriented matrix.
#'
#' Returns a `[y, x]` matrix (row 1 = northernmost). Offsets are 0-based
#' pixel coordinates. If `nodata` is supplied, matching cells (and any
#' file-level NA) are rewritten to NaN (D8) and the result is numeric.
#'
#' @param path Path or VSI URL readable by GDAL.
#' @param band 1-based band index.
#' @param x_off,y_off,x_size,y_size 0-based pixel window.
#' @param nodata Length-0 or length-1 sentinel to promote to NaN.
#' @param open_options GDAL open options ("KEY=VALUE").
#' @return A numeric `y_size x x_size` matrix.
#' @export
gdal_read_window <- function(path, band, x_off, y_off, x_size, y_size,
                             nodata = numeric(0),
                             open_options = character(0),
                             out = c("matrix", "raw_f32")) {
  out <- match.arg(out)
  ds <- .gdal_handle(path, open_options)
  v <- ds$read(band, x_off, y_off, x_size, y_size, x_size, y_size)
  v <- as.numeric(v)
  if (length(nodata) == 1L) {
    v[!is.na(v) & v == nodata] <- NaN
  }
  v[is.na(v) & !is.nan(v)] <- NaN        # GDAL-side masked values
  # GDAL's buffer is already row-major: the raw f32 store payload (D19)
  # converts it directly, skipping the byrow transpose below.
  if (out == "raw_f32") return(.sv_from_vec(v, y_size, x_size))
  matrix(v, nrow = y_size, byrow = TRUE)
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
#' Delegates every pixel of cross-CRS math to the GDAL warper (decision
#' D5): `-te`/`-ts` pin the output grid exactly to `target_grid`.
#' Float targets without a source nodata get `-dstnodata nan` so area
#' outside the source footprint reads as NaN, not 0 (D8).
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
  vrt <- tempfile(fileext = ".vrt")
  num <- function(v) sprintf("%.17g", v)
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
  ok <- gdalraster::warp(src_path, vrt, t_srs = target_grid@crs,
                         cl_arg = args, quiet = TRUE)
  if (!isTRUE(ok)) stop("gdalwarp to VRT failed for ", src_path)
  vrt
}

#' Create an output GTiff for a grid.
#'
#' A single non-spatial dim ("t" or "band") maps to GTiff bands; more
#' than one is an error.
#'
#' @param path Destination path.
#' @param grid Output `GridSpec`.
#' @param nodata Optional sentinel to record in metadata (all bands).
#' @param options GTiff creation options.
#' @return An open dataset object; caller must `$close()`.
#' @export
gdal_create_output <- function(path, grid, nodata = numeric(0),
                               options = c("COMPRESS=DEFLATE")) {
  dt <- .gdal_dtype_rev[[grid@dtype]]
  if (is.null(dt)) stop("cannot write dtype: ", grid@dtype)
  outer <- grid@dims[!names(grid@dims) %in% c("x", "y")]
  if (length(outer) > 1L)
    stop("cannot write a grid with more than one non-spatial dim (",
         paste(names(outer), collapse = ", "), ")")
  n_bands <- if (length(outer) == 1L) as.integer(outer[[1L]]) else 1L
  ds <- gdalraster::create("GTiff", path,
                           grid@dims[["x"]], grid@dims[["y"]], n_bands, dt,
                           options = options, return_obj = TRUE)
  ds$setGeoTransform(grid@transform)
  ds$setProjection(grid@crs)
  if (length(nodata) == 1L)
    for (b in seq_len(n_bands)) ds$setNoDataValue(b, nodata)
  ds
}

#' Write a garry-oriented matrix into an open output dataset.
#'
#' NaN cells demote to `nodata` when given (D8 reversed at the sink);
#' writing NaN into an integer band without a sentinel is an error.
#'
#' @param ds Open dataset from `gdal_create_output()`.
#' @param x_off,y_off 0-based destination offsets.
#' @param m `[y, x]` matrix.
#' @param dtype Output dtype (for the NaN check).
#' @param nodata Optional sentinel for NaN demotion.
#' @param band 1-based destination band.
#' @return Invisibly, `NULL`.
#' @export
gdal_write_window <- function(ds, x_off, y_off, m, dtype,
                              nodata = numeric(0), band = 1L) {
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
  if (length(nodata) == 1L) {
    v[is.na(v)] <- nodata
  } else if (anyNA(v) && .dtype_family(dtype) != "float") {
    stop("result contains nodata (NaN) but no `nodata` sentinel was ",
         "given for integer output dtype ", dtype)
  }
  ds$write(as.integer(band), x_off, y_off, nc, nr, v)
  invisible(NULL)
}

# Warp sources straight into a caller-held f32 buffer via GDAL's MEM:::
# DATAPOINTER driver (warp-on-read, the GDAL-direct fast path): GDAL reads
# (windowed vsicurl for remote items), reprojects and mosaics `srcs` into `buf`
# in place, in the order given (last source wins on overlap). `-r near` and
# nan dst-nodata match the composite path. Returns the same `buf`, now filled.
# D13: the sole home for the direct-to-memory GDAL warp mechanics (the MEM
# driver open gate, the raw data pointer, and the warp) -- callers stay clean.
gdal_warp_to_buffer <- function(buf, nx, ny, gtstr, wkt, srcs, srcnodata = NULL) {
  gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")   # >=3.10 gate
  ptr <- gdalraster:::.get_data_ptr(buf)
  dsn <- sprintf(
    "MEM:::DATAPOINTER=%s,PIXELS=%d,LINES=%d,BANDS=1,DATATYPE=Float32,GEOTRANSFORM=%s",
    ptr, nx, ny, gtstr)
  o <- methods::new(gdalraster::GDALRaster, dsn, FALSE)
  o$setProjection(wkt)
  cl <- c("-r", "near", "-q", "-dstnodata", "nan")
  if (length(srcnodata) == 1L)
    cl <- c(cl, "-srcnodata", format(srcnodata, scientific = FALSE))
  gdalraster::warp(srcs, o, "", cl_arg = cl)
  o$close()
  buf
}

#' Apply garry's default GDAL configuration for remote COG reads.
#'
#' Sets the GDAL config options the composite / warp-on-read path and
#' cloud-optimised remote reads want: HTTP multiplexing over HTTP/2, the
#' odc-stac retry cadence and timeouts, a capped block cache (GDAL
#' defaults to 5% of RAM *per process*, which many daemons would
#' multiply), single-range COG-header ingest, a skipped directory scan
#' and `.tif`-only vsicurl probing for fast remote opens, and the MEM
#' driver open gate the direct warp needs. `garry_daemons()` calls this
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
  sc("GDAL_HTTP_RETRY_CODES", "429,500,502,503")
  sc("GDAL_HTTP_TIMEOUT", "60")
  sc("GDAL_HTTP_CONNECTTIMEOUT", "10")
  sc("GDAL_CACHEMAX", "256")                       # MB, per process
  sc("GDAL_INGESTED_BYTES_AT_OPEN", "32768")       # one range grabs the COG header
  sc("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
  sc("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".tif")
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
    stop("failed to create GTI index dataset: ", path)

  v <- methods::new(gdalraster::GDALVector, path, layer, read_only = FALSE)
  on.exit(v$close(), add = TRUE)
  for (i in seq_len(nrow(entries))) {
    ft <- as.list(entries[i, field_cols, drop = FALSE])
    ft$geom <- if (has_geom) entries$geom[[i]] else {
      gdalraster::bbox_to_wkt(as.numeric(
        entries[i, c("xmin", "ymin", "xmax", "ymax")]))
    }
    if (!v$createFeature(ft))
      stop("failed to write index feature ", i)
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
#' The fetch half of the phase 12 fetch/assemble split: a plain
#' `gdal_translate -srcwin` of the window intersecting `ext` (plus a
#' warp-kernel `margin` in source pixels), native dtype and blocks —
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
                              margin = 8L) {
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
  # Uncompressed on purpose: the cache lives on tmpfs for one slice
  # assembly, and re-encoding (DEFLATE) costs more CPU across a
  # 20-plus-fetcher fleet than the bytes are worth (source blocks
  # still arrive compressed; only the local copy is raw).
  gdalraster::translate(
    location, out_file,
    cl_arg = c("-srcwin", x0, y0, x1 - x0, y1 - y0,
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
#' @export
gti_open_options <- function(grid = NULL, filter = NULL,
                             sort_field = NULL, sort_asc = TRUE) {
  num <- function(v) sprintf("%.17g", v)
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
