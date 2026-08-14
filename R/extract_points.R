#' @include lazy_raster.R dataset.R write_tif.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# extract_points(): sample a MATERIALISED cube at points.
#
# gdalraster::pixel_extract() already samples a raster properly --
# nearest/bilinear/cubic interpolation, kernel windows, point reprojection,
# a RAM guard -- and reads only the blocks holding points, measured ~100x
# faster than computing a whole raster to keep a few thousand cells
# (design/sample-sink.md). garry therefore delegates rather than
# reimplementing, and only adds what it uniquely knows: which local files a
# lazy object reads.
#
# Deliberately NOT automatic: a lazy pipeline is refused rather than
# quietly materialised. Writing a cube is an expensive, visible step and
# the caller should own the decision (and keep the cube, which is almost
# always wanted again). Hidden IO is the ambiguity this design removes.
# ---------------------------------------------------------------------------

#' Extract raster values at points.
#'
#' Samples a raster at points via [gdalraster::pixel_extract()], which reads
#' only the blocks containing points. Accepts anything that function accepts
#' (a path or a `GDALRaster`, passed through untouched) plus a garry
#' `LazyRaster`/`LazyDataset` that is already **materialised** -- i.e. one
#' whose graph is a bare source over local files, as [materialise()]
#' returns.
#'
#' An unmaterialised pipeline is an error, not a silent cube write. Getting
#' pixels onto disk costs real time and space, and the cube is almost always
#' wanted again (for the predict pass, say), so the caller should own that
#' step:
#'
#' ```r
#' cube <- materialise(pipeline)     # explicit, reusable
#' vals <- extract_points(cube, pts)
#' ```
#'
#' `xy` may be a [wk::xy()] point vector, in which case its CRS supplies
#' `xy_srs` and GDAL reprojects as needed; a matrix or data frame behaves
#' exactly as in gdalraster.
#'
#' @param raster A `LazyRaster`, `LazyDataset`, raster path, or
#'   `GDALRaster` object.
#' @param xy Points: a [wk::xy()] vector (its CRS supplies `xy_srs`), or a
#'   two-column matrix/data frame as gdalraster expects.
#' @param bands Bands to extract (default all).
#' @param interp Interpolation: `NULL`/`"nearest"` (default), `"bilinear"`,
#'   `"cubic"`, `"cubicspline"`.
#' @param ... Passed to [gdalraster::pixel_extract()] (`krnl_dim`,
#'   `xy_srs`, `max_ram`, `as_data_frame`).
#' @return As [gdalraster::pixel_extract()]: a matrix, or a data frame with
#'   `as_data_frame = TRUE`.
#' @seealso [materialise()], [collect()]
#' @examples
#' \dontrun{
#' pts <- wk::xy(c(512300, 514800), c(4600100, 4601900), crs = "EPSG:32632")
#' cube <- materialise(composite)
#' extract_points(cube, pts, interp = "bilinear")
#' extract_points("composite.tif", pts)   # a path works too
#' }
#' @export
extract_points <- function(raster, xy, bands = NULL, interp = NULL, ...) {
  if (S7::S7_inherits(raster, LazyDatasetGroups)) {
    cli::cli_abort(c(
      "{.fn extract_points} does not take a grouped dataset.",
      "i" = "Extract from each group, or {.fn reduce_over} the groups first."
    ))
  }
  lazy <- S7::S7_inherits(raster, LazyRaster) ||
    S7::S7_inherits(raster, LazyDataset)
  pt <- .px_points(xy)
  args <- list(xy = pt$xy, bands = bands, interp = interp, ...)
  if (!is.null(pt$srs) && is.null(args$xy_srs)) {
    args$xy_srs <- pt$srs
  }
  if (!lazy) {
    return(do.call(gdal_pixel_extract, c(list(raster), args)))
  }
  src <- .px_local_sources(raster)
  if (is.null(src)) {
    cli::cli_abort(c(
      "{.arg raster} is a lazy pipeline with no pixels to read.",
      "i" = "Materialise it first: {.code cube <- materialise(x)}, then extract from {.code cube}.",
      "i" = "Extraction reads only the blocks holding points, so it needs the cube on disk -- and you almost always want to keep it."
    ))
  }
  if (length(src) == 1L) {
    return(do.call(gdal_pixel_extract, c(list(unname(src)), args)))
  }
  # one file per band (a dataset over separate sources): extract from each
  # and bind, preserving band order
  cols <- lapply(unname(src), function(p) {
    as.matrix(do.call(gdal_pixel_extract, c(list(p), args)))
  })
  out <- do.call(cbind, cols)
  colnames(out) <- rep(names(src), vapply(cols, ncol, integer(1)))
  out
}

# wk_xy -> list(xy = 2-col matrix, srs = CRS string); anything else passes
# through with no CRS opinion (gdalraster's own xy_srs still applies).
.px_points <- function(xy) {
  if (!inherits(xy, "wk_xy")) {
    return(list(xy = xy, srs = NULL))
  }
  crs <- wk::wk_crs(xy)
  if (is.null(crs) || inherits(crs, "wk_crs_inherit")) {
    cli::cli_abort(c(
      "{.arg xy} has no CRS.",
      "i" = "Set one with {.fn wk::wk_set_crs}, or pass a plain matrix."
    ))
  }
  f <- unclass(xy)
  list(
    xy = cbind(as.numeric(f$x), as.numeric(f$y)),
    srs = wk::wk_crs_proj_definition(crs)
  )
}

# The local file(s) a lazy object reads directly, or NULL when it needs
# computing first. A bare source graph (one SourceNode per band, no compute)
# is exactly what materialise() hands back, so sampling its output costs
# nothing but the read.
.px_local_sources <- function(x) {
  bands <- if (S7::S7_inherits(x, LazyDataset)) {
    lapply(x@bands, function(b) if (length(b) == 1L) b[[1L]] else NULL)
  } else {
    list(x)
  }
  if (any(vapply(bands, is.null, logical(1)))) {
    return(NULL) # multi-slice bands: not a plain cube
  }
  paths <- character(0)
  for (b in bands) {
    ids <- .reachable(b@graph, b@node_id)
    if (length(ids) != 1L) {
      return(NULL) # any compute in the graph: must materialise
    }
    n <- graph_get(b@graph, ids[[1L]])
    if (!S7::S7_inherits(n, SourceNode) || .gdal_is_remote(n@path)) {
      return(NULL)
    }
    paths <- c(paths, n@path)
  }
  if (length(unique(paths)) == 1L) {
    return(paths[[1L]])
  }
  stats::setNames(paths, names(bands))
}
