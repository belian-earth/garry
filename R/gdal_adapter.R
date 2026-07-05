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

# Dataset handle cache: open once per path per process. Handles are
# read-only; invalidate with .gdal_handle_reset() (tests, long sessions).
.gdal_handles <- new.env(parent = emptyenv())

.gdal_handle <- function(path) {
  key <- path
  h <- .gdal_handles[[key]]
  if (!is.null(h)) return(h)
  h <- methods::new(gdalraster::GDALRaster, path, read_only = TRUE)
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
#' @return A list: `grid` (`GridSpec`), `nodata` (length 0 or 1),
#'   `block_dim` (integer length 2, x then y).
#' @export
gdal_grid_spec <- function(path, band = 1L) {
  ds <- .gdal_handle(path)
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
#' @return A numeric `y_size x x_size` matrix.
#' @export
gdal_read_window <- function(path, band, x_off, y_off, x_size, y_size,
                             nodata = numeric(0)) {
  ds <- .gdal_handle(path)
  v <- ds$read(band, x_off, y_off, x_size, y_size, x_size, y_size)
  v <- as.numeric(v)
  if (length(nodata) == 1L) {
    v[!is.na(v) & v == nodata] <- NaN
  }
  v[is.na(v) & !is.nan(v)] <- NaN        # GDAL-side masked values
  matrix(v, nrow = y_size, byrow = TRUE)
}
