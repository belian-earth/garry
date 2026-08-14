#' @include lazy_raster.R dataset.R write_tif.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# pixel_extract(): gdalraster's point sampler, extended to garry objects.
#
# gdalraster::pixel_extract() already samples a raster at points properly --
# nearest/bilinear/cubic interpolation, kernel windows, point reprojection,
# a RAM guard -- and it reads only the blocks holding points, which on a
# local cube measured ~100x faster than gathering the whole raster
# (design/sample-sink.md). What it cannot do is sample a lazy PIPELINE.
#
# So garry does not reimplement sampling: it exports its own pixel_extract
# which masks gdalraster's, hands anything that is not a garry object
# straight through unchanged, and for a lazy object gives GDAL something to
# read -- the source path when the graph is already a bare local source
# (what materialise() returns), else a temporary materialised cube.
# ---------------------------------------------------------------------------

#' Extract raster values at points.
#'
#' garry's extension of [gdalraster::pixel_extract()]: identical for every
#' input that function already accepts (a path or a `GDALRaster`, passed
#' through untouched), and additionally accepting a `LazyRaster` or
#' `LazyDataset`.
#'
#' A lazy object has no pixels until it runs, so garry gives GDAL something
#' to read. When the graph is already a bare source over local files -- what
#' [materialise()] returns -- those files are read directly. Otherwise the
#' pipeline is written to a temporary uncompressed cube, sampled, and the
#' cube removed. Writing first is deliberate: GDAL reads only the
#' blocks containing points, so extraction from a cube is far cheaper than
#' computing a whole raster to keep a few thousand cells. If you want the
#' cube as well, call [materialise()] yourself and pass the result.
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
#' # a lazy pipeline: materialised to a temporary cube, then sampled
#' pixel_extract(composite, pts, interp = "bilinear")
#' # keep the cube if you want it for anything else
#' cube <- materialise(composite)
#' pixel_extract(cube, pts)
#' }
#' @export
pixel_extract <- function(raster, xy, bands = NULL, interp = NULL, ...) {
  if (S7::S7_inherits(raster, LazyDatasetGroups)) {
    cli::cli_abort(c(
      "{.fn pixel_extract} does not take a grouped dataset.",
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
    # not already on disk: write a transient cube, sample it, drop it.
    # Uncompressed because it lives for one call and compression would cost
    # more than the read it serves.
    tmp <- tempfile("garry-extract-", fileext = ".tif")
    on.exit(unlink(tmp), add = TRUE)
    write_tif(
      raster, tmp,
      creation_options = c("TILED=YES", "COMPRESS=NONE", "BIGTIFF=IF_SAFER")
    )
    src <- tmp
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
