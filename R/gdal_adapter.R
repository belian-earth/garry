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
  h <- if (length(open_options) > 0L) {
    methods::new(gdalraster::GDALRaster, path, TRUE, open_options)
  } else {
    methods::new(gdalraster::GDALRaster, path, read_only = TRUE)
  }
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
                             open_options = character(0)) {
  ds <- .gdal_handle(path, open_options)
  v <- ds$read(band, x_off, y_off, x_size, y_size, x_size, y_size)
  v <- as.numeric(v)
  if (length(nodata) == 1L) {
    v[!is.na(v) & v == nodata] <- NaN
  }
  v[is.na(v) & !is.nan(v)] <- NaN        # GDAL-side masked values
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
  if (length(nodata) == 1L) {
    m[is.na(m)] <- nodata
  } else if (anyNA(m) && .dtype_family(dtype) != "float") {
    stop("result contains nodata (NaN) but no `nodata` sentinel was ",
         "given for integer output dtype ", dtype)
  }
  ds$write(as.integer(band), x_off, y_off, ncol(m), nrow(m),
           as.numeric(t(m)))
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
  invisible(path)
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
