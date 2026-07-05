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

# Dataset handle cache: open once per (path, open options) per process.
# Handles are read-only; invalidate with .gdal_handle_reset() (tests,
# long sessions).
.gdal_handles <- new.env(parent = emptyenv())

.gdal_handle <- function(path, open_options = character(0)) {
  key <- paste(c(path, open_options), collapse = "\x1f")
  h <- .gdal_handles[[key]]
  if (!is.null(h)) return(h)
  h <- if (length(open_options) > 0L) {
    methods::new(gdalraster::GDALRaster, path, TRUE, open_options)
  } else {
    methods::new(gdalraster::GDALRaster, path, read_only = TRUE)
  }
  .gdal_handles[[key]] <- h
  h
}

.gdal_handle_reset <- function() {
  for (k in ls(.gdal_handles, all.names = TRUE)) {
    try(.gdal_handles[[k]]$close(), silent = TRUE)
    rm(list = k, envir = .gdal_handles)
  }
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

#' Create an output GTiff for a grid (single band).
#'
#' @param path Destination path.
#' @param grid Output `GridSpec`.
#' @param nodata Optional sentinel to record in metadata.
#' @param options GTiff creation options.
#' @return An open dataset object; caller must `$close()`.
#' @export
gdal_create_output <- function(path, grid, nodata = numeric(0),
                               options = c("COMPRESS=DEFLATE")) {
  dt <- .gdal_dtype_rev[[grid@dtype]]
  if (is.null(dt)) stop("cannot write dtype: ", grid@dtype)
  ds <- gdalraster::create("GTiff", path,
                           grid@dims[["x"]], grid@dims[["y"]], 1L, dt,
                           options = options, return_obj = TRUE)
  ds$setGeoTransform(grid@transform)
  ds$setProjection(grid@crs)
  if (length(nodata) == 1L) ds$setNoDataValue(1L, nodata)
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
#' @return Invisibly, `NULL`.
#' @export
gdal_write_window <- function(ds, x_off, y_off, m, dtype,
                              nodata = numeric(0)) {
  if (length(nodata) == 1L) {
    m[is.na(m)] <- nodata
  } else if (anyNA(m) && .dtype_family(dtype) != "float") {
    stop("result contains nodata (NaN) but no `nodata` sentinel was ",
         "given for integer output dtype ", dtype)
  }
  ds$write(1L, x_off, y_off, ncol(m), nrow(m), as.numeric(t(m)))
  invisible(NULL)
}
