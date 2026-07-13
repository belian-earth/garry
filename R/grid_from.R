#' @include grid.R gdal_adapter.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Deriving an analysis GridSpec from an area of interest: a lon/lat bbox
# (grid_from_bbox) or a vector file/URL (grid_from_src). The CRS is chosen for
# the AOI and centred on it -- LAEA by default, because analysis wants an
# equal-area basis, not UTM's storage-oriented zones. Ported and adapted from
# vrtility's bbox_to_projected()/ogr_* helpers (dropping rlang/glue).
# ---------------------------------------------------------------------------

# Choose a projected CRS for a lon/lat bbox and reproject the bbox into it.
# Returns list(crs = <wkt>, extent = c(xmin, ymin, xmax, ymax)). The bbox is a
# rectangle, so its centroid is just the midpoint.
.project_bbox <- function(bbox_ll, projection, ellps) {
  lon <- (bbox_ll[[1L]] + bbox_ll[[3L]]) / 2
  lat <- (bbox_ll[[2L]] + bbox_ll[[4L]]) / 2
  crs <- switch(projection,
    utm = {
      zone <- floor((lon + 180) / 6) %% 60L + 1L
      paste0("EPSG:", (if (lat >= 0) 32600L else 32700L) + zone)
    },
    laea = sprintf("+proj=laea +lon_0=%.10g +lat_0=%.10g +ellps=%s +no_defs",
                   lon, lat, ellps),
    aeqd = sprintf("+proj=aeqd +lon_0=%.10g +lat_0=%.10g +ellps=%s +no_defs",
                   lon, lat, ellps),
    pconic = sprintf(paste("+proj=pconic +lon_0=%.10g +lat_0=%.10g",
                           "+lat_1=%.10g +lat_2=%.10g +ellps=%s +no_defs"),
                     lon, lat, bbox_ll[[4L]], bbox_ll[[2L]], ellps),
    eqdc = sprintf(paste("+proj=eqdc +lon_0=%.10g +lat_1=%.10g +lat_2=%.10g",
                         "+ellps=%s +no_defs"),
                   lon, bbox_ll[[4L]], bbox_ll[[2L]], ellps))
  wkt <- gdalraster::srs_to_wkt(crs)
  te <- gdalraster::transform_bounds(bbox_ll, gdalraster::srs_to_wkt("EPSG:4326"),
                                     wkt)
  list(crs = wkt, extent = as.numeric(te))
}

# extent snapped out to whole multiples of res, with matching integer dims.
.grid_from_extent <- function(crs, extent, res, buffer, dtype) {
  res <- rep(as.numeric(res), length.out = 2L)
  stopifnot(all(res > 0))
  e <- extent + c(-buffer, -buffer, buffer, buffer)
  xmin <- floor(e[[1L]] / res[[1L]]) * res[[1L]]
  xmax <- ceiling(e[[3L]] / res[[1L]]) * res[[1L]]
  ymin <- floor(e[[2L]] / res[[2L]]) * res[[2L]]
  ymax <- ceiling(e[[4L]] / res[[2L]]) * res[[2L]]
  nx <- as.integer(round((xmax - xmin) / res[[1L]]))
  ny <- as.integer(round((ymax - ymin) / res[[2L]]))
  grid_spec(crs, c(xmin, ymin, xmax, ymax), c(nx, ny), dtype = dtype)
}

#' Build an analysis grid from a lon/lat bounding box.
#'
#' Picks a projected CRS for the area of interest (centred on the bbox), reprojects
#' the extent into it, snaps the extent out to whole multiples of `res`, and
#' returns a ready `GridSpec`.
#'
#' The default projection is Lambert azimuthal equal-area (`"laea"`) centred on
#' the AOI: analysis wants an equal-area basis, so areas, fractions and densities
#' are correct and there are no zone seams. `"utm"` is available when you want
#' storage-oriented zone alignment (it is not equal-area). `"aeqd"` is azimuthal
#' equidistant (true distances from the centre); `"pconic"`/`"eqdc"` are conics
#' using the bbox's north/south edges as standard parallels. Centred projections
#' are bespoke (no EPSG code), so a grid's CRS may print as its projection name
#' rather than an EPSG code.
#'
#' @param bbox Length-4 numeric lon/lat bbox (xmin, ymin, xmax, ymax), EPSG:4326.
#' @param res Target resolution in the projected CRS units (metres for the
#'   supported projections); a scalar, or `c(xres, yres)`.
#' @param projection Projection family; the first is the default (see Details).
#' @param ellps Ellipsoid for the centred projections.
#' @param buffer Extent padding in projected units, applied before snapping.
#' @param dtype Grid dtype.
#' @return A `GridSpec`.
#' @examples
#' # An equal-area 30 m grid over a small AOI.
#' g <- grid_from_bbox(c(144.13, -7.725, 144.47, -7.475), res = 30)
#' @export
grid_from_bbox <- function(bbox, res,
                           projection = c("laea", "aeqd", "utm", "pconic", "eqdc"),
                           ellps = "WGS84", buffer = 0, dtype = "f32") {
  stopifnot(is.numeric(bbox), length(bbox) == 4L,
            bbox[[1L]] < bbox[[3L]], bbox[[2L]] < bbox[[4L]])
  projection <- match.arg(projection)
  proj <- .project_bbox(as.numeric(bbox), projection, ellps)
  .grid_from_extent(proj$crs, proj$extent, res, buffer, dtype)
}

#' Build an analysis grid from a vector source.
#'
#' Reads the bounding box of a vector file or URL (any OGR-readable source: GeoJSON,
#' GeoPackage, shapefile, ...), transforms it to lon/lat, then chooses a projected
#' CRS and builds a `GridSpec` exactly as `grid_from_bbox()` does.
#'
#' @param x Path or URL to a vector source.
#' @param res Target resolution in projected units (see `grid_from_bbox()`).
#' @param projection,ellps,buffer,dtype As in `grid_from_bbox()`.
#' @return A `GridSpec`.
#' @examples
#' \dontrun{
#' target <- grid_from_src("catchment.gpkg", res = 30)
#' }
#' @export
grid_from_src <- function(x, res,
                          projection = c("laea", "aeqd", "utm", "pconic", "eqdc"),
                          ellps = "WGS84", buffer = 0, dtype = "f32") {
  stopifnot(is.character(x), length(x) == 1L, nzchar(x))
  grid_from_bbox(gdal_vector_bbox_ll(x), res, projection = match.arg(projection),
                 ellps = ellps, buffer = buffer, dtype = dtype)
}
