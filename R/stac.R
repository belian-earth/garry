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
  rlang::check_installed("rstac", reason = "for STAC queries.")
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

# Package env: MPC collection name -> signing token (in-memory cache).
.mpc_token_cache <- new.env(parent = emptyenv())

#' Sign Planetary Computer STAC items, caching the token per collection.
#'
#' Microsoft Planetary Computer assets need a SAS token appended to each asset
#' href before they can be read. Unlike `rstac::items_sign()`, which requests a
#' token on every call and can storm the MPC signing endpoint into 429s when
#' signing many items, `stac_sign_mpc()` caches the **collection-level** token in
#' memory AND on disk (under [tools::R_user_dir()]) and reuses it until it
#' expires (`msft:expiry`) -- one request per collection instead of one per item.
#' Use it in place of `rstac::items_sign()` after [stac_query()].
#'
#' @param items An rstac `doc_items` from [stac_query()].
#' @param subscription_key Optional MPC subscription key (defaults to the
#'   `MPC_TOKEN` environment variable). Not required for public data.
#' @return `items` with every asset href signed.
#' @export
stac_sign_mpc <- function(items,
                          subscription_key = Sys.getenv("MPC_TOKEN", unset = NA)) {
  .require_rstac()
  rlang::check_installed("httr2", reason = "to request Planetary Computer tokens.")
  if (!length(items$features)) {
    cli::cli_warn("No STAC items to sign.")
    return(items)
  }
  token <- .mpc_token(items$features[[1L]]$collection, subscription_key)
  items$features <- lapply(items$features, function(f) {
    f$assets <- lapply(f$assets, function(a) {
      a$href <- paste0(a$href, "?", token); a
    })
    f
  })
  items
}

# The collection SAS token: memory cache, then disk cache, then a fresh request
# (saved to both). Reused until msft:expiry.
.mpc_token <- function(collection, subscription_key) {
  hit <- .mpc_token_lookup(collection)
  if (!is.null(hit)) return(hit)
  url <- paste0("https://planetarycomputer.microsoft.com/api/sas/v1/token/",
                collection)
  req <- httr2::req_headers(httr2::request(url), Accept = "application/json")
  if (!is.na(subscription_key))
    req <- httr2::req_headers(req, "Ocp-Apim-Subscription-Key" = subscription_key)
  tok <- httr2::resp_body_json(httr2::req_perform(req))
  assign(collection, tok, envir = .mpc_token_cache)
  saveRDS(tok, .mpc_token_file(collection))
  tok$token
}

# The valid token string from the memory or disk cache, or NULL. Expired entries
# are dropped from memory as a side effect.
.mpc_token_lookup <- function(collection) {
  unexpired <- function(tok) {
    exp <- as.POSIXct(tok[["msft:expiry"]], format = "%Y-%m-%dT%H:%M:%SZ",
                      tz = "UTC")
    !is.na(exp) && exp > Sys.time()
  }
  if (exists(collection, envir = .mpc_token_cache, inherits = FALSE)) {
    tok <- get(collection, envir = .mpc_token_cache)
    if (unexpired(tok)) return(tok$token)
    rm(list = collection, envir = .mpc_token_cache)
  }
  f <- .mpc_token_file(collection)
  if (file.exists(f)) {
    tok <- readRDS(f)
    if (unexpired(tok)) {
      assign(collection, tok, envir = .mpc_token_cache)
      return(tok$token)
    }
  }
  NULL
}

.mpc_token_file <- function(collection) {
  dir <- tools::R_user_dir("garry", "cache")
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  file.path(dir, paste0(gsub("[^A-Za-z0-9_.-]", "_", collection),
                        "_mpc_token.rds"))
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

#' Filter a source table by maximum cloud cover.
#'
#' @param sources A `stac_sources()` table.
#' @param max_cloud_cover Keep rows strictly below this percentage
#'   (rows with unknown cloud cover are kept).
#' @return The filtered table.
#' @export
stac_filter_cloud <- function(sources, max_cloud_cover) {
  if (inherits(sources, "doc_items")) {
    .require_rstac()
    return(rstac::items_filter(sources, filter_fn = function(x) {
      cc <- x$properties[["eo:cloud_cover"]]
      is.null(cc) || cc < max_cloud_cover
    }))
  }
  keep <- is.na(sources$cloud_cover) | sources$cloud_cover < max_cloud_cover
  sources[keep, , drop = FALSE]
}

#' Drop STAC items (or sources) that barely overlap an area of interest.
#'
#' Keeps items whose bounding box covers at least `min_coverage` of the AOI
#' `bbox` (fraction of the AOI area, from a planar bbox overlap -- a fast proxy,
#' not geodesic). Works on a STAC `doc_items` or a `stac_sources()` table.
#'
#' @param sources A STAC `doc_items` or a `stac_sources()` data frame.
#' @param bbox AOI bounding box `c(xmin, ymin, xmax, ymax)` in the item CRS
#'   (STAC bboxes are lon/lat).
#' @param min_coverage Minimum AOI-overlap fraction to keep an item (0-1).
#' @return The filtered `doc_items` / data frame.
#' @export
stac_filter_coverage <- function(sources, bbox, min_coverage = 0.5) {
  stopifnot(length(bbox) == 4L, min_coverage >= 0, min_coverage <= 1)
  aoi <- (bbox[[3L]] - bbox[[1L]]) * (bbox[[4L]] - bbox[[2L]])
  frac <- function(xmin, ymin, xmax, ymax) {
    ix <- pmax(0, pmin(xmax, bbox[[3L]]) - pmax(xmin, bbox[[1L]]))
    iy <- pmax(0, pmin(ymax, bbox[[4L]]) - pmax(ymin, bbox[[2L]]))
    (ix * iy) / aoi
  }
  if (inherits(sources, "doc_items")) {
    .require_rstac()
    return(rstac::items_filter(sources, filter_fn = function(x)
      frac(x$bbox[[1L]], x$bbox[[2L]], x$bbox[[3L]], x$bbox[[4L]]) >= min_coverage))
  }
  keep <- frac(sources$xmin, sources$ymin, sources$xmax, sources$ymax) >= min_coverage
  sources[keep, , drop = FALSE]
}

#' Filter STAC items by orbit state (Sentinel-1 ascending / descending).
#'
#' Keeps items whose `sat:orbit_state` is in `orbit_state`. STAC-only: the
#' orbit state is not carried in the `stac_sources()` table, so pass a
#' `doc_items` (filter before building the dataset).
#'
#' @param sources A STAC `doc_items`.
#' @param orbit_state One or more of `"descending"`, `"ascending"`.
#' @return The filtered `doc_items`.
#' @export
stac_filter_orbit <- function(sources,
                              orbit_state = c("descending", "ascending")) {
  orbit_state <- rlang::arg_match(orbit_state, multiple = TRUE)
  if (!inherits(sources, "doc_items"))
    cli::cli_abort(c(
      "{.fn stac_filter_orbit} needs a STAC {.cls doc_items}.",
      "i" = "The orbit state is not in the {.fn stac_sources} table; filter before converting."))
  .require_rstac()
  rstac::items_filter(sources, filter_fn = function(x)
    isTRUE(x$properties[["sat:orbit_state"]] %in% orbit_state))
}

#' Keep only the named assets in a STAC item collection (or sources table).
#'
#' Drops every other asset from each item -- fewer assets to carry through the
#' pipeline, and fewer to sign. Apply it BEFORE [stac_sign_mpc()] so only the
#' assets you keep get a token (MPC returns every band plus thumbnails and
#' rendered previews). Items left with none of the requested assets are dropped.
#' Polymorphic: a STAC `doc_items` or a `stac_sources()` table.
#'
#' @param sources A STAC `doc_items` or a `stac_sources()` data frame.
#' @param assets Asset names to keep.
#' @return The filtered `doc_items` / data frame.
#' @export
stac_filter_assets <- function(sources, assets) {
  if (inherits(sources, "doc_items")) {
    .require_rstac()
    present <- unique(unlist(lapply(sources$features,
                                    function(ft) names(ft$assets))))
    miss <- setdiff(assets, present)
    if (length(miss))
      cli::cli_warn("asset{?s} not present in any item (ignored): {.val {miss}}")
    sources$features <- Filter(
      function(ft) length(ft$assets) > 0L,
      lapply(sources$features, function(ft) {
        ft$assets <- ft$assets[names(ft$assets) %in% assets]
        ft
      }))
    return(sources)
  }
  sources[sources$asset %in% assets, , drop = FALSE]
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
  if (inherits(sources, "doc_items")) {
    .require_rstac()
    keys <- vapply(sources$features, function(x) paste(
      x$properties$platform %||% "", x$properties$datetime %||% "",
      x$properties[["sat:orbit_state"]] %||% "",
      paste(round(x$bbox, 4L), collapse = ",")), character(1))
    return(rstac::items_select(sources, which(!duplicated(keys))))
  }
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
#' `"day"` truncates the UTC datetime: one satellite overpass that
#' crosses local midnight in UTC terms splits into two slices.
#' `"solar_day"` instead shifts each timestamp by the local solar
#' offset (`lon` degrees x 240 s, the odc-stac rule) before taking the
#' date, so acquisitions group by the local day of the overpass; the
#' two agree everywhere except within ~an overpass of the UTC date
#' line at `lon`.
#'
#' @param sources A `stac_sources()` table.
#' @param granularity "day", "month", "exact", or "solar_day".
#' @param lon Longitude (degrees, WGS84) whose solar time defines
#'   `"solar_day"` — use the centre of the analysis area. Defaults to
#'   the circular mean of the source footprint centres (safe across
#'   the antimeridian).
#' @return The table with a `slice` column.
#' @export
stac_time_slices <- function(sources, granularity = c("day", "month",
                                                      "exact",
                                                      "solar_day"),
                             lon = NULL) {
  granularity <- rlang::arg_match(granularity)
  sources$slice <- switch(granularity,
    day = substr(sources$datetime, 1L, 10L),
    month = substr(sources$datetime, 1L, 7L),
    exact = sources$datetime,
    solar_day = {
      if (is.null(lon)) {
        mid <- (sources$xmin + sources$xmax) / 2
        rad <- mid * pi / 180
        lon <- atan2(mean(sin(rad)), mean(cos(rad))) * 180 / pi
      }
      stopifnot(length(lon) == 1L, is.finite(lon))
      utc <- .stac_parse_datetime(sources$datetime)
      format(utc + round(lon * 240), "%Y-%m-%d", tz = "UTC")
    })
  sources
}

#' Rename assets to a common band schema.
#'
#' Harmonising collections that name the same physical band differently (e.g.
#' HLS Landsat `B05` and HLS Sentinel-2 `B8A` are both the narrow NIR): supply a
#' `c(old = new)` map and the `asset` column is rewritten to the shared names.
#' Assets absent from the map are dropped by default, so the map doubles as the
#' band selector. Include identity entries (`Fmask = "Fmask"`) to keep a band
#' under its own name.
#'
#' After renaming, [stac_merge()] concatenates the collections into one table.
#' A band a collection lacks needs no placeholder: [lazy_dataset()] gives each
#' band only the slices that carry it, and [mask()] pairs those slices with the
#' QA band by name (a Landsat-only thermal band masks against the Landsat Fmask
#' slices), so ragged bands reduce over exactly their own observations.
#'
#' @param sources A `stac_sources()` table.
#' @param mapping Named character `c(old = new)`: original asset -> common name.
#' @param drop_unmapped Drop assets not named in `mapping` (default `TRUE`)? When
#'   `FALSE`, unmapped assets pass through unchanged.
#' @return The table with a rewritten `asset` column.
#' @export
stac_rename_assets <- function(sources, mapping, drop_unmapped = TRUE) {
  if (!is.character(mapping) || is.null(names(mapping)) || anyNA(names(mapping)))
    cli::cli_abort("{.arg mapping} must be a named character vector {.code c(old = new)}.")
  warn_missing <- function(present) {
    m <- setdiff(names(mapping), present)
    if (length(m))
      cli::cli_warn("mapping name{?s} not present in {.arg sources} (ignored): {.val {m}}")
  }
  if (inherits(sources, "doc_items")) {
    .require_rstac()
    warn_missing(unique(unlist(lapply(sources$features,
                                      function(ft) names(ft$assets)))))
    sources$features <- lapply(sources$features, function(ft) {
      an  <- names(ft$assets)
      hit <- match(an, names(mapping))
      if (isTRUE(drop_unmapped)) {
        keep <- !is.na(hit); ft$assets <- ft$assets[keep]
        an <- an[keep]; hit <- hit[keep]
      }
      if (length(ft$assets))
        names(ft$assets) <- ifelse(is.na(hit), an, unname(mapping)[hit])
      ft
    })
    return(sources)
  }
  warn_missing(sources$asset)
  if (isTRUE(drop_unmapped))
    sources <- sources[sources$asset %in% names(mapping), , drop = FALSE]
  hit <- match(sources$asset, names(mapping))
  sources$asset <- ifelse(is.na(hit), sources$asset, unname(mapping)[hit])
  rownames(sources) <- NULL
  sources
}

#' Concatenate source tables into one harmonised collection.
#'
#' Row-binds `stac_sources()` tables (typically after [stac_rename_assets()] has
#' brought them onto a shared band schema) and re-sorts. Every table must carry
#' the same columns. Same-`slice` acquisitions from different collections
#' co-mosaic (use `granularity = "exact"` downstream to keep them as separate
#' time steps).
#'
#' @param ... Two or more `stac_sources()` tables (or a single list of them).
#' @return One combined table.
#' @export
stac_merge <- function(...) {
  tabs <- list(...)
  # unwrap a single list-of-tables arg (but not a single doc_items, itself a list)
  if (length(tabs) == 1L && !is.data.frame(tabs[[1L]]) &&
      is.list(tabs[[1L]]) && !inherits(tabs[[1L]], "doc_items"))
    tabs <- tabs[[1L]]
  tabs <- Filter(Negate(is.null), tabs)
  is_di <- vapply(tabs, function(t) inherits(t, "doc_items"), logical(1))
  if (any(is_di)) {
    if (!all(is_di))
      cli::cli_abort("{.fn stac_merge} cannot mix {.cls doc_items} and source tables.")
    .require_rstac()
    merged <- tabs[[1L]]
    merged$features <- do.call(c, lapply(tabs, function(t) t$features))
    return(merged)
  }
  tabs <- Filter(function(t) nrow(t) > 0L, tabs)
  if (length(tabs) < 1L) cli::cli_abort("{.fn stac_merge} needs at least one non-empty table.")
  cols <- names(tabs[[1L]])
  for (t in tabs)
    if (!setequal(names(t), cols))
      cli::cli_abort("all source tables must have the same columns.")
  out <- do.call(rbind, lapply(tabs, function(t) t[, cols, drop = FALSE]))
  out <- out[order(out$datetime, out$item_id, out$asset), , drop = FALSE]
  rownames(out) <- NULL
  out
}

# RFC 3339 datetimes (STAC item `datetime`) to POSIXct UTC. Accepts
# "Z", "+HH:MM"/"-HH:MM", "+HHMM" offsets and fractional seconds.
.stac_parse_datetime <- function(x) {
  x <- sub("Z$", "+0000", x)
  x <- sub("([+-]\\d{2}):(\\d{2})$", "\\1\\2", x)
  out <- as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%OS%z", tz = "UTC")
  if (anyNA(out))
    .garry_error(paste0("unparseable STAC datetime(s): ",
                        paste(utils::head(x[is.na(out)], 3L),
                              collapse = ", ")),
                 "garry_stac_error")
  out
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
                           path = tempfile(fileext = ".gti.fgb"),
                           crs = "EPSG:4326") {
  stopifnot("slice" %in% names(sources))
  rows <- sources[sources$asset == asset, , drop = FALSE]
  if (nrow(rows) == 0L) cli::cli_abort("no rows for asset: {.val {asset}}")
  entries <- rows[, c("location", "datetime", "slice", "cloud_cover",
                      "xmin", "ymin", "xmax", "ymax")]
  entries$cloud_cover[is.na(entries$cloud_cover)] <- -1
  if (!crs_equal(gdalraster::srs_to_wkt(crs),
                 gdalraster::srs_to_wkt("EPSG:4326"))) {
    # PROJ selects coordinate operations per bbox (~ms each), but tiled
    # collections repeat a handful of footprints (HLS: fixed MGRS
    # squares), so transform the unique bboxes and fan back out.
    bb <- as.matrix(entries[, c("xmin", "ymin", "xmax", "ymax")])
    key <- do.call(paste, c(as.data.frame(bb), sep = "\x1f"))
    first <- !duplicated(key)
    b <- gdalraster::transform_bounds(bb[first, , drop = FALSE],
                                      "EPSG:4326", crs)
    if (!is.matrix(b)) b <- matrix(b, nrow = 1L)   # one unique bbox
    entries[, c("xmin", "ymin", "xmax", "ymax")] <-
      b[match(key, key[first]), , drop = FALSE]
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
#' @param lon Longitude for `granularity = "solar_day"` (see
#'   `stac_time_slices()`).
#' @return A list: `stack` (`LazyRaster`), `slices` (character),
#'   `index` (path).
#' @export
lazy_stac_stack <- function(sources, grid, asset,
                            granularity = "day",
                            sort_field = "datetime",
                            nodata = NULL, lon = NULL) {
  sources <- stac_time_slices(sources, granularity, lon = lon)
  idx <- stac_gti_index(sources, asset, crs = grid@crs)
  slices <- sort(unique(sources$slice[sources$asset == asset]))
  # One metadata probe per asset, not per slice: every slice opens the
  # same index pinned to the same grid, so the only unknowns (source
  # dtype, native block, file nodata) are shared. Per-slice discovery
  # costs a remote COG header fetch each, serially, on the host.
  meta <- gdal_grid_spec(paste0("GTI:", idx),
                         open_options = gti_open_options(grid))
  if (is.null(nodata) && length(meta$nodata) == 1L)
    nodata <- meta$nodata
  graph <- graph_new()
  layers <- lapply(slices, function(sl) {
    lazy_source(
      paste0("GTI:", idx),
      graph = graph,
      nodata = nodata,
      open_options = gti_open_options(
        grid,
        filter = sprintf("slice = '%s'", sl),
        sort_field = sort_field),
      grid = meta$grid,
      block_dim = meta$block_dim)
  })
  list(stack = lazy_stack(layers), slices = slices, index = idx)
}
