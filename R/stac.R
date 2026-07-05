#' @include gdal_adapter.R lazy_raster.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# STAC discovery (decision D18, discovery half). Ported from vrtility's
# stac layer with one structural change: search results rectangularise
# IMMEDIATELY into a source table (one row per item x asset), and all
# filtering/grouping happens on that table in plain R. rstac is used
# only for the API interaction (search, pagination, optional signing),
# so it stays in Suggests and everything downstream tests offline.
#
# The source table IS the mosaic index: stac_gti_index() writes it as a
# GTI-readable layer, and lazy_stac_stack() opens one FILTERed slice
# per datetime group (D18). Planetary Computer signing, measured on the
# HLS benchmark: PRE-SIGN hrefs before stac_sources() (one cached SAS
# token per collection, e.g. rstac::items_sign 'sign_planetary_computer'
# - vrtility's approach). Per-URL GDAL signing
# (VSICURL_PC_URL_SIGNING=YES) causes a signing-request storm across
# daemon fleets and MPC 429 rate limits; reserve it for jobs long
# enough (>~45 min) that pre-signed tokens would expire mid-run.
# ---------------------------------------------------------------------------

.require_rstac <- function() {
  if (!requireNamespace("rstac", quietly = TRUE))
    stop("the rstac package is required for STAC queries; ",
         "install.packages(\"rstac\")", call. = FALSE)
}

#' Query a STAC API and return the item collection.
#'
#' Thin port of vrtility's `stac_query()`: GET with POST fallback,
#' full pagination via `rstac::items_fetch()`.
#'
#' @param bbox Length-4 numeric, EPSG:4326 (xmin, ymin, xmax, ymax).
#' @param stac_source STAC API root URL.
#' @param collection Collection id.
#' @param start_date,end_date Dates (any lubridate-parseable form).
#' @param limit Page size requested from the API.
#' @return An rstac `doc_items` object.
#' @export
stac_query <- function(bbox, stac_source, collection, start_date, end_date,
                       limit = 999) {
  .require_rstac()
  datetime <- paste0(
    format(as.POSIXct(start_date, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ"), "/",
    format(as.POSIXct(end_date, tz = "UTC"), "%Y-%m-%dT%H:%M:%SZ"))
  search <- rstac::stac_search(
    rstac::stac(stac_source),
    collections = collection,
    bbox = bbox,
    datetime = datetime,
    limit = limit)
  res <- tryCatch(rstac::get_request(search),
                  error = function(e) rstac::post_request(search))
  rstac::items_fetch(res)
}

#' Rectangularise STAC items into a source table.
#'
#' One row per item x asset: `location` (GDAL-readable href), `asset`,
#' `datetime`, `cloud_cover`, footprint columns (`xmin`..`ymax`, EPSG:
#' 4326 from the item bbox), and `item_id`. This table is the single
#' interface between discovery and the mosaic layer; filters below
#' operate on it in plain R.
#'
#' @param items An rstac `doc_items` object (or any list with the same
#'   `features` structure).
#' @param assets Optional character vector restricting assets.
#' @return A data.frame.
#' @export
stac_sources <- function(items, assets = NULL) {
  feats <- items$features
  stopifnot(length(feats) > 0L)
  rows <- lapply(feats, function(ft) {
    anames <- names(ft$assets)
    if (!is.null(assets)) anames <- intersect(anames, assets)
    if (length(anames) == 0L) return(NULL)
    hrefs <- vapply(ft$assets[anames], function(a) a$href, character(1))
    cc <- ft$properties[["eo:cloud_cover"]]
    data.frame(
      item_id = ft$id %||% NA_character_,
      asset = anames,
      location = vapply(hrefs, .gdal_href, character(1), USE.NAMES = FALSE),
      datetime = ft$properties$datetime %||% NA_character_,
      cloud_cover = if (is.null(cc)) NA_real_ else as.numeric(cc),
      xmin = ft$bbox[[1L]], ymin = ft$bbox[[2L]],
      xmax = ft$bbox[[3L]], ymax = ft$bbox[[4L]],
      row.names = NULL
    )
  })
  out <- do.call(rbind, rows)
  out[order(out$datetime, out$item_id, out$asset), , drop = FALSE]
}

# http(s) hrefs need the vsicurl prefix for GDAL.
.gdal_href <- function(href) {
  if (grepl("^(http|https)://", href)) paste0("/vsicurl/", href) else href
}

#' Filter a source table by maximum cloud cover.
#'
#' @param sources A `stac_sources()` table.
#' @param max_cloud_cover Keep rows strictly below this percentage
#'   (rows with unknown cloud cover are kept).
#' @return The filtered table.
#' @export
stac_filter_cloud <- function(sources, max_cloud_cover) {
  keep <- is.na(sources$cloud_cover) |
    sources$cloud_cover < max_cloud_cover
  sources[keep, , drop = FALSE]
}

#' Drop duplicate acquisitions (identical footprint and datetime).
#'
#' Duplicate items are a known Planetary Computer quirk; equality uses
#' the footprint rounded to 4 decimal places plus the datetime, per
#' asset (vrtility's rule).
#'
#' @param sources A `stac_sources()` table.
#' @return The deduplicated table.
#' @export
stac_drop_duplicates <- function(sources) {
  key <- paste(sources$asset, sources$datetime,
               round(sources$xmin, 4), round(sources$ymin, 4),
               round(sources$xmax, 4), round(sources$ymax, 4))
  sources[!duplicated(key), , drop = FALSE]
}

#' Group acquisitions into time slices.
#'
#' Adds a `slice` column (the datetime truncated to `granularity`);
#' tiles sharing a slice mosaic together in `lazy_stac_stack()`.
#'
#' @param sources A `stac_sources()` table.
#' @param granularity "day", "month", or "exact".
#' @return The table with a `slice` column.
#' @export
stac_time_slices <- function(sources, granularity = c("day", "month",
                                                      "exact")) {
  granularity <- match.arg(granularity)
  sources$slice <- switch(granularity,
    day = substr(sources$datetime, 1L, 10L),
    month = substr(sources$datetime, 1L, 7L),
    exact = sources$datetime)
  sources
}

#' Write a source table as a GTI index for one asset.
#'
#' Footprints are stored in `crs` (transform them from the table's
#' EPSG:4326 bboxes), so the index layer SRS matches the grid the GTI
#' dataset will be pinned to: exact culling geometry, no SRS_BEHAVIOR
#' juggling, works from GDAL 3.10 up.
#'
#' @param sources A `stac_sources()` table with a `slice` column (see
#'   `stac_time_slices()`).
#' @param asset Which asset's rows to index.
#' @param path Index path; defaults to a tempfile.
#' @param crs CRS for the index footprints (use the target grid's CRS).
#' @return The index path, invisibly.
#' @export
stac_gti_index <- function(sources, asset,
                           path = tempfile(fileext = ".gti.gpkg"),
                           crs = "EPSG:4326") {
  stopifnot("slice" %in% names(sources))
  rows <- sources[sources$asset == asset, , drop = FALSE]
  if (nrow(rows) == 0L) stop("no rows for asset: ", asset)
  entries <- rows[, c("location", "datetime", "slice", "cloud_cover",
                      "xmin", "ymin", "xmax", "ymax")]
  entries$cloud_cover[is.na(entries$cloud_cover)] <- -1
  if (!crs_equal(gdalraster::srs_to_wkt(crs),
                 gdalraster::srs_to_wkt("EPSG:4326"))) {
    for (i in seq_len(nrow(entries))) {
      b <- gdalraster::transform_bounds(
        as.numeric(entries[i, c("xmin", "ymin", "xmax", "ymax")]),
        "EPSG:4326", crs)
      entries[i, c("xmin", "ymin", "xmax", "ymax")] <- as.list(b)
    }
  }
  gti_index_create(entries, path, crs = crs)
  invisible(path)
}

#' Lazy time-sliced stack of one STAC asset on a target grid.
#'
#' Builds a GTI index for `asset`, then opens one mosaic per time slice
#' pinned to `grid` (mixed source CRS is fine: the GTI driver
#' reprojects per tile) and stacks them along `t`. Overlaps within a
#' slice resolve by ascending `sort_field` (highest drawn on top).
#'
#' @param sources A `stac_sources()` table.
#' @param grid Target `GridSpec` for every slice.
#' @param asset Asset name to stack.
#' @param granularity Slice granularity (see `stac_time_slices()`).
#' @param sort_field Index field ordering overlaps within a slice.
#' @param nodata Optional nodata override passed to each slice source.
#' @return A list: `stack` (`LazyRaster`), `slices` (character),
#'   `index` (path).
#' @export
lazy_stac_stack <- function(sources, grid, asset,
                            granularity = "day",
                            sort_field = "datetime",
                            nodata = NULL) {
  sources <- stac_time_slices(sources, granularity)
  idx <- stac_gti_index(sources, asset, crs = grid@crs)
  slices <- sort(unique(sources$slice[sources$asset == asset]))
  graph <- graph_new()
  layers <- lapply(slices, function(sl) {
    lazy_source(
      paste0("GTI:", idx),
      graph = graph,
      nodata = nodata,
      open_options = gti_open_options(
        grid,
        filter = sprintf("slice = '%s'", sl),
        sort_field = sort_field))
  })
  list(stack = lazy_stack(layers), slices = slices, index = idx)
}
