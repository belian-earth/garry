#' @include lazy_raster.R stac.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# LazyDataset: a named, multi-band, multi-time lazy object (the xarray
# Dataset analog; LazyRaster is the DataArray analog). See design/dataset-api.md.
#
# Verbs (lazy_map / focal / reduce_over / mask) apply across every band by
# default, so users stop writing nested lapply()s over bands and time slices.
#
# Internal representation: band-major, and each band is a list of PER-TIME-SLICE
# 2D LazyRasters (not a single (t, y, x) node). This mirrors the proven composite
# path and keeps focal morphology per slice. The temporal reduce stacks a band's slices into (t, y, x) and collapses t;
# `collect()`/`stack_bands()` then assemble the band axis. One object at the API
# level; the per-slice layout is an implementation detail.
# ---------------------------------------------------------------------------

#' A named, multi-band, multi-time lazy dataset.
#'
#' The dataset holds one entry per band; each entry is a list of per-time-slice
#' `LazyRaster`s on a shared grid and intermediate representation (IR) graph.
#' Construct one with [lazy_dataset()] (from a STAC source table or raster
#' files) or [as_dataset()] (from `LazyRaster`s you already have) rather than
#' calling this class constructor directly. Apply [lazy_map()], [focal_map()],
#' [reduce_over()] and [apply_mask()] across all bands; index a single band with
#' `ds[["B04"]]` or a sub-dataset with `ds[c("B04", "B03")]`; [collect()] to
#' materialise.
#'
#' @param graph The shared IR `Graph`.
#' @param bands Named list; each element is a list of per-slice `LazyRaster`s.
#' @param mask_asset Length-0 or length-1 name of the QA/mask band, if any.
#' @param steps Internal display-only pipeline log, shown by `plan_draw()`; does
#'   not affect execution.
#' @return A `LazyDataset`.
#' @export
LazyDataset <- S7::new_class(
  "LazyDataset",
  properties = list(
    graph = Graph,
    bands = S7::class_list,
    mask_asset = S7::class_character,
    steps = S7::class_list
  ),
  validator = function(self) {
    if (length(self@bands) < 1L || is.null(names(self@bands))) {
      return("`bands` must be a non-empty named list")
    }
    if (length(self@mask_asset) > 1L) {
      return("`mask_asset` must be length 0 or 1")
    }
    if (
      length(self@mask_asset) == 1L && !self@mask_asset %in% names(self@bands)
    ) {
      return("`mask_asset` must name one of `bands`")
    }
    NULL
  }
)

# Spatial grid shared by every band (from the first band's first slice).
.ds_grid <- function(x) x@bands[[1L]][[1L]]@grid

# Value bands are every band except the QA/mask band.
.ds_value_bands <- function(x) setdiff(names(x@bands), x@mask_asset)

# `bands` of a dataset verb: NULL, or names (or positions) of x's bands.
.ds_check_bands <- function(x, bands, call = rlang::caller_env()) {
  if (is.null(bands)) {
    return(NULL)
  }
  nm <- if (is.numeric(bands)) names(x@bands)[bands] else bands
  bad <- if (is.character(nm)) nm[is.na(nm) | !nm %in% names(x@bands)] else bands
  if (!is.character(nm) || length(bad) || anyNA(nm)) {
    cli::cli_abort(
      "{.arg bands} must name bands of the dataset ({.val {names(x@bands)}}); got {.val {bands}}.",
      call = call
    )
  }
  nm
}

# One display step for the pipeline log (see plan_draw()); execution ignores it.
.step <- function(kind, label, detail = NULL) {
  list(kind = kind, label = label, detail = detail)
}

# `x` with `bands`, one more recorded step, and `mask_asset`.
.ds_step <- function(x, bands, kind, detail, label = kind, mask_asset = x@mask_asset) {
  LazyDataset(
    graph = x@graph,
    bands = bands,
    mask_asset = mask_asset,
    steps = c(x@steps, list(.step(kind, label, detail = detail)))
  )
}

# The bands of `x`, each slice of those in `sel` through `f`.
.ds_map_layers <- function(x, sel, f) {
  bands <- x@bands
  for (a in sel) {
    bands[[a]] <- lapply(x@bands[[a]], f)
  }
  bands
}

# Format an integer set as compact ranges, e.g. 0:3 -> "0-3",
# c(0,1,2,3,8,9,10,11) -> "0-3, 8-11". Uses an en dash when UTF-8.
.rng <- function(v) {
  v <- sort(unique(as.integer(v)))
  if (!length(v)) {
    return("")
  }
  dash <- if (cli::is_utf8_output()) "\u2013" else "-"
  brk <- c(0L, which(diff(v) != 1L), length(v))
  parts <- vapply(
    seq_len(length(brk) - 1L),
    function(i) {
      seg <- v[(brk[i] + 1L):brk[i + 1L]]
      if (length(seg) == 1L) {
        as.character(seg)
      } else {
        paste0(seg[1L], dash, seg[length(seg)])
      }
    },
    character(1)
  )
  paste(parts, collapse = ", ")
}

# Re-home a LazyRaster onto graph `g` (no-op if already there).
.ds_reimport <- function(lr, g) {
  if (identical(g@nodes, lr@graph@nodes)) {
    return(lr)
  }
  id <- graph_import(g, lr@graph, lr@node_id)
  LazyRaster(graph = g, node_id = id, grid = lr@grid)
}

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

#' Build a lazy dataset from a STAC source table or raster file(s).
#'
#' The one way into any source. Two input forms:
#'
#' * a STAC `doc_items` / `stac_sources()` table: one band per asset band,
#'   each a time-sliced GTI mosaic pinned to `grid` (mixed source CRS is
#'   fine; the GTI driver reprojects per tile). A single-band asset takes
#'   the asset's name. Every band of a multi-band asset (e.g. a SAR product
#'   packing several polarisations into one COG) becomes its own dataset
#'   band, named `<asset>_<description>`, or `<asset>_b<index>` when the
#'   file carries no band descriptions; `bands` selects and renames them.
#' * a character path, or a vector of tile paths (mosaicked where they
#'   share a CRS and one pixel lattice, kept apart and warped together
#'   otherwise; tiles off that lattice need `grid`, and tiles kept apart
#'   must agree on dtype, on any nodata they declare and, with
#'   `scale = TRUE`, on their scale and offset): one band
#'   per file band, one time slice. This is the multi-band raster entry --
#'   geo-embedding stacks (e.g. Alpha Earth's 64-band tiles), Zarr via the
#'   GDAL driver, any multi-band file GDAL reads. Each band is its own
#'   source, so reads of a band-interleaved file fan out band-by-band
#'   across the reader pool (per-band tasks through per-daemon handles:
#'   the measured fastest remote shape, design/gdal-multiband-fanout.md).
#'   When the bands share storage (a pixel-interleaved file, a Zarr chunk
#'   spanning bands), [collect()] reads a window's bands in one task
#'   instead, so the shared bytes are fetched once. Bands are named by
#'   their file band descriptions when present, else `b<index>`;
#'   `grid = NULL` stays on the file's native grid, and a supplied `grid`
#'   inserts an [align_to()] warp per band. Value transforms go downstream as
#'   [lazy_map()]s, which fuse onto the read at [collect()]; 8-bit codes that
#'   must be decoded before resampling, such as [dequantize_aef()]'s, go
#'   through `decode`.
#'
#'   An N-D array with a time dimension, such as a `(time, band, y, x)`
#'   Zarr array (`ZARR:"<store>":/<array>`), becomes bands x time slices:
#'   GDAL's classic view flattens it to one band per (time, band) pair, and
#'   garry reads the dimension tags GDAL puts on each band to rebuild the
#'   axes. Bands take the band dimension's coordinate values as names
#'   (else `b<index>`) and slices take the time coordinate's (e.g. years);
#'   pick slices with [time_sel()], or build only some with `time`.
#'
#'   A Zarr store's root (a `.zarr` path or URL, or `ZARR:"<root>"`),
#'   given alone, reads the store's arrays that overlap `grid`, so a store
#'   of one array per UTM zone needs no connection string per zone. garry
#'   lists the arrays from the store's consolidated metadata, one document,
#'   and takes each one's CRS and extent from the zarr-conventions
#'   attributes it declares (`proj:code`, `proj:wkt2` or `proj:projjson`;
#'   `spatial:bbox`, or `spatial:transform` with `spatial:shape`), on the
#'   array or its nearest group. GDAL places an array that declares none,
#'   and lists the arrays of a store without consolidated metadata (over
#'   HTTP, only where the server lists directories). garry keeps the arrays
#'   whose extent overlaps `grid`, says which, and reads them as it reads a
#'   vector of them; GDAL must place each one where the store declares it,
#'   or the call aborts and names connection strings that read it as GDAL
#'   places it. Where two arrays hold data for a cell, the later one's value
#'   is read: arrays in the grid's CRS go last, so their own pixels win,
#'   and the others go first, in the order of their paths in the store. An
#'   array's extent can reach well past the data it holds: each OlmoEarth
#'   zone's spans 983 km east to west, so a grid at Jasper (53 degrees
#'   north, in zone 11's CRS) also reads zones 10 and 12, which show only
#'   where zone 11 holds no data. Give the arrays as connection strings to
#'   read fewer. `array` names the array to read in each group when the
#'   arrays with a CRS and extent carry more than one name. Without `grid`
#'   the store must hold one such array.
#'
#' All bands share one intermediate representation (IR) graph, so a mask
#' defined once (see [apply_mask()]) is computed once and dedup'd across bands, and
#' [collect()] plans the whole dataset in one pass.
#'
#' @param sources A STAC `doc_items` (from [stac_query()], optionally
#'   filtered), a `stac_sources()` table, or a character path / vector of
#'   paths to (multi-band) raster files (local, `/vsicurl/`, or bare
#'   `http(s)://`, prefixed automatically), or `ZARR:"<store>":/<array>`
#'   strings, whose bare `https://` store is prefixed the same way. Or the
#'   root of a Zarr store, whose arrays that overlap `grid` are read (see
#'   the description).
#' @param grid Target [GridSpec()] for every band. Required for the table
#'   form; `NULL` (the default) keeps the file form on its native grid.
#' @param assets Character vector of value assets to load (table form), or of
#'   band names to select (file form, when the file carries band
#'   descriptions).
#' @param bands Source bands to select (default: all). File form: an
#'   integer vector of band indices (positions along the band dimension
#'   for an N-D array), mutually exclusive with `assets`.
#'   Table form: a list named by asset, each entry an integer vector of
#'   that asset's band indices; names on the indices rename the dataset
#'   bands, e.g. `list(enclosure_tiff = c(hh = 1, vh = 2, vv = 3))`.
#'   Assets left out read every band; `mask_asset` always reads band 1.
#' @param decode File form: a function decoding the source's 8-bit codes
#'   (Byte or Int8), such as [dequantize_aef()]. It is evaluated once on
#'   every code to make a table. Each source cell's code is decoded
#'   through the table first, the nodata code to NaN; resampling then
#'   works on the decoded values. With `resampling = "average"` onto a
#'   grid 3x coarser, each target cell is the mean of the valid decoded
#'   values of its 3 x 3 source cells, the order a nonlinear code needs,
#'   and a cell whose source cells are all nodata stays NaN. Values are
#'   Float32. A `mask_asset` band is read as stored, not decoded, and every
#'   band and source must declare one nodata code. Reads go through a
#'   lookup-table VRT; the source's own grid, a window of its pixels, or an
#'   aligned coarser grid read with `"near"` or `"average"` read the codes
#'   and decode them directly, about five times faster. `NULL` (the
#'   default) reads the codes as they are.
#' @param time File form, N-D array: the time slices to build, selected
#'   by label as [time_sel()] selects them (`"2024"`, or positions).
#'   `lazy_dataset(src, grid, time = "2024")` is
#'   `time_sel(lazy_dataset(src, grid), "2024")` without building the
#'   other slices' bands first, which matters for long time series of
#'   many bands. `NULL` (the default) builds every slice.
#' @param mask_asset Optional QA/mask asset (e.g. `"Fmask"`, `"SCL"`), or in the
#'   file form the name of one selected band; loaded alongside the value assets
#'   and used as the default `from` in [apply_mask()].
#' @param granularity Table form: time-slice granularity (see
#'   [stac_time_slices()]). The file form refuses it: a file's slices come
#'   from the file; select them with `time`.
#' @param nodata Nodata handling: `NULL` (per-band file metadata), a scalar
#'   (applied to every asset), or a named numeric keyed by dataset band name
#'   or by asset (a band name wins; bands with no key fall back to file
#'   metadata). An asset key covers every band of a multi-band asset, and a
#'   key that names no band or asset of the source aborts. Reflectance and
#'   QA bands usually need different sentinels, so the named form is
#'   typical, e.g.
#'   `c(B04 = -9999, B03 = -9999, Fmask = 255)`. In the file form a
#'   sentinel replaces the file's own, whose cells then read as data. In
#'   the table form the tiles' own sentinel stays masked as well, since
#'   each slice's mosaic is built on it, and [align_to()] refuses such a
#'   band.
#' @param resampling GDAL resampling for the warp-on-read onto `grid`, or
#'   onto the grid of several sources kept apart: a scalar
#'   (every value band) or a named character keyed by dataset band name or
#'   by asset, as for `nodata` (bands with no key fall back to `"near"`). `mask_asset` is always read `"near"` regardless, since
#'   interpolating packed QA bits corrupts them. `"near"` (the default)
#'   preserves exact source values; use `"bilinear"`, `"average"`, `"cubic"`,
#'   ... to interpolate. Resample after the fact instead with [align_to()].
#' @param scale Apply each value band's scale/offset at read. `FALSE`
#'   (default) reads raw digital numbers. `TRUE` discovers the affine from
#'   the assets' file metadata (the GDAL band scale/offset QGIS applies;
#'   one asset per band is probed and the collection is assumed
#'   homogeneous) and every read returns `v * scale + offset`, applied
#'   after the nodata sentinel becomes NaN. A scalar or named numeric
#'   (keyed by band name or asset, as for `nodata`) supplies scales
#'   explicitly. Discovery only consults the files themselves: STAC
#'   metadata is never read, so collections
#'   whose files carry no scaling metadata (e.g. Planetary Computer
#'   Sentinel-2 L2A) warn, read raw and need scaling explicitly.
#'   `mask_asset` is never scaled.
#' @param offset Explicit additive offset(s) (scalar or named by band or
#'   asset) used when `scale` is numeric; defaults to 0. A band with an
#'   offset and no scale of its own takes scale 1. Ignored when `scale` is
#'   logical.
#' @param array With a Zarr store's root as `sources` (see the
#'   description): the name of the array to read in each group, the last
#'   part of its path, such as `"embeddings"`. Needed only when the
#'   store's arrays with a CRS and extent carry more than one name; `NULL`
#'   (the default) takes the one name they share.
#' @return A `LazyDataset`.
#' @seealso [group_by_time()], [collect()]
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' ds <- lazy_dataset(f)
#' names(ds)
#' ds$nir
#' @export
lazy_dataset <- function(
  sources,
  grid = NULL,
  assets = NULL,
  mask_asset = NULL,
  granularity = "day",
  nodata = NULL,
  resampling = "near",
  scale = FALSE,
  offset = NULL,
  bands = NULL,
  decode = NULL,
  time = NULL,
  array = NULL
) {
  if (!isFALSE(scale) && !isTRUE(scale) && !is.numeric(scale)) {
    cli::cli_abort(
      "{.arg scale} must be `FALSE`, `TRUE`, or numeric (scalar or named by band or asset).",
      class = c("garry_source_error", "garry_error")
    )
  }
  .check_band_args(list(
    nodata = nodata,
    resampling = resampling,
    scale = scale,
    offset = offset
  ))
  if (
    !is.null(array) &&
      (!is.character(array) ||
        length(array) != 1L ||
        is.na(array) ||
        !nzchar(array))
  ) {
    cli::cli_abort(
      "{.arg array} must be one array name, such as {.val embeddings}.",
      class = c("garry_source_error", "garry_error")
    )
  }
  if (is.character(sources)) {
    if (!missing(granularity)) {
      cli::cli_abort(c(
        "{.arg granularity} groups STAC items into slices.",
        "i" = "A file's slices come from the file: select them with {.arg time}."
      ))
    }
    return(.ds_from_files(
      .ds_store_sources(sources, grid, array),
      grid,
      assets,
      mask_asset,
      bands,
      resampling,
      nodata,
      scale,
      offset,
      decode,
      time
    ))
  }
  .assert_class(grid, GridSpec, "GridSpec")
  if (!is.null(array)) {
    cli::cli_abort(
      "{.arg array} picks the arrays of a Zarr store; STAC items have none.",
      class = c("garry_source_error", "garry_error")
    )
  }
  if (!is.null(decode)) {
    cli::cli_abort(c(
      "{.arg decode} decodes a coded raster file.",
      "i" = "Decode STAC assets with {.fn lazy_map}."
    ))
  }
  if (!is.null(time)) {
    cli::cli_abort(c(
      "{.arg time} selects the slices of an N-D file source.",
      "i" = "Filter the STAC items by date instead, or use {.fn time_sel}."
    ))
  }
  if (length(assets) < 1L) {
    cli::cli_abort("{.arg assets} must name at least one asset.")
  }
  all_assets <- unique(c(assets, mask_asset))
  if (!is.null(bands)) {
    if (!is.list(bands) || is.null(names(bands)) || !all(nzchar(names(bands)))) {
      cli::cli_abort(c(
        "In the table form, {.arg bands} is a list named by asset.",
        "i" = "For example {.code bands = list(visual = c(red = 1, green = 2))}."
      ))
    }
    bad <- setdiff(names(bands), setdiff(assets, mask_asset))
    if (length(bad)) {
      cli::cli_abort(c(
        "{.arg bands} names {?an asset/assets} not among the value {.arg assets}: {.val {bad}}.",
        "i" = "{.arg mask_asset} always reads band 1."
      ))
    }
  }
  # Accept a STAC `doc_items` directly (the discovery/filter object), converting
  # it to the sources table internally -- so the STAC pipeline stays on the rstac
  # object end to end. A plain data.frame (non-STAC / manual sources) passes
  # through unchanged.
  if (inherits(sources, "doc_items")) {
    offered <- .stac_asset_names(sources$features)
    sources <- stac_sources(sources, assets = all_assets)
  } else {
    offered <- unique(sources$asset)
  }
  sources <- stac_time_slices(sources, granularity)

  resolve_nodata <- function(nm, a, meta_nodata) {
    .band_value(
      nodata,
      nm,
      a,
      default = if (length(meta_nodata) == 1L) meta_nodata
    )
  }

  if (!all(resampling %in% .resampling_methods)) {
    cli::cli_abort(c(
      "Invalid {.arg resampling} method{?s}: {.val {setdiff(resampling, .resampling_methods)}}.",
      "i" = "One of {.val {(.resampling_methods)}}."
    ))
  }
  resolve_resampling <- function(nm, a) {
    # QA never interpolates
    if (a %in% mask_asset) "near" else .band_value(resampling, nm, a, default = "near")
  }

  # Per-asset read affine (TIFF metadata only). Discovery probes the GTI
  # mosaic first (free: the grid probe below already opens it) and falls
  # back to the asset's first item when GTI does not propagate the band
  # scale/offset. One asset per band; the collection is assumed
  # homogeneous (documented caveat, e.g. the S2 baseline-04 cutover).
  resolve_affine <- function(nm, a, b, meta) {
    .resolve_scale(
      if (a %in% mask_asset) FALSE else .band_scale(scale, offset, nm, a),
      .band_value(offset, nm, a),
      function() {
        if (length(meta$scale) == 1L) {
          return(meta)
        }
        gdal_grid_spec(sources$location[sources$asset == a][[1L]], band = b)
      },
      what = nm
    )
  }

  graph <- graph_new()
  out <- list()
  for (a in all_assets) {
    idx <- stac_gti_index(sources, a, crs = grid@crs)
    gti <- paste0("GTI:", idx)
    # The GTI driver infers band count, dtype and nodata per band from the
    # first tile, so one index serves every band of a multi-band asset.
    nb <- .gdal_handle(gti, gti_open_options(grid))$getRasterCount()
    sel <- if (!is.null(mask_asset) && a %in% mask_asset) {
      stats::setNames(1L, a)
    } else {
      .ds_asset_bands(
        a,
        nb,
        sources$location[sources$asset == a][[1L]],
        bands[[a]]
      )
    }
    slices <- sort(unique(sources$slice[sources$asset == a]))
    for (k in seq_along(sel)) {
      b <- sel[[k]]
      nm <- names(sel)[[k]]
      meta <- gdal_grid_spec(
        gti,
        band = b,
        open_options = gti_open_options(grid)
      )
      nd <- resolve_nodata(nm, a, meta$nodata)
      aff <- resolve_affine(nm, a, b, meta)
      rs <- resolve_resampling(nm, a)
      layers <- lapply(slices, function(sl) {
        lazy_source(
          gti,
          band = b,
          graph = graph,
          nodata = nd,
          open_options = gti_open_options(
            grid,
            filter = .glue("slice = '{sl}'"),
            sort_field = "datetime"
          ),
          grid = meta$grid,
          block_dim = meta$block_dim,
          resampling = rs,
          scale = if (length(aff$scale) == 1L) aff$scale else FALSE,
          offset = if (length(aff$offset) == 1L) aff$offset else NULL,
          name = nm
        )
      })
      names(layers) <- slices
      if (!is.null(out[[nm]])) {
        cli::cli_abort(c(
          "Two dataset bands are both named {.val {nm}}.",
          "i" = "Rename one through {.arg bands}."
        ))
      }
      out[[nm]] <- layers
    }
  }
  .check_band_keys(
    list(nodata = nodata, resampling = resampling, scale = scale, offset = offset),
    c(names(out), offered)
  )
  LazyDataset(
    graph = graph,
    bands = out,
    mask_asset = if (is.null(mask_asset)) {
      character(0)
    } else {
      as.character(mask_asset)
    },
    steps = list(.step("source", "source", detail = max(lengths(out))))
  )
}

# The per-band arguments of lazy_dataset(): one value for every band, or
# values named by dataset band or asset. Several unnamed values, a blank
# name or a repeated one do not say which band takes which value.
.check_band_args <- function(args, call = rlang::caller_env()) {
  ok <- vapply(
    args,
    function(x) {
      keys <- names(x)
      if (is.null(keys)) {
        return(is.null(x) || length(x) == 1L)
      }
      !anyNA(keys) && all(nzchar(keys)) && !anyDuplicated(keys)
    },
    logical(1)
  )
  if (!all(ok)) {
    arg <- names(args)[!ok][[1L]]
    cli::cli_abort(c(
      "{.arg {arg}} must be one value for every band, or values with unique names.",
      "i" = "Name each value by band or asset, e.g. {.code c(red = 1, nir = 2)}."
    ), class = c("garry_source_error", "garry_error"), call = call)
  }
  invisible(args)
}

# Every name in a per-band argument must be something the source holds. A
# typo would otherwise leave that band on its file metadata, or on "near",
# with nothing to show for it.
.check_band_keys <- function(args, known, call = rlang::caller_env()) {
  for (arg in names(args)) {
    bad <- setdiff(names(args[[arg]]), known)
    if (length(bad)) {
      cli::cli_abort(c(
        "{.arg {arg}} names no band or asset of the source: {.val {bad}}.",
        "i" = "The source holds {.val {unique(known)}}."
      ), class = c("garry_source_error", "garry_error"), call = call)
    }
  }
  invisible(args)
}

# One band's entry of a per-band argument: the value every band shares, or
# the one keyed by band name, then by asset, so `c(enclosure_tiff = -9999)`
# covers every band of a multi-band asset and `c(hh = -9999)` overrides one
# of them. A band with no key takes `default`.
.band_value <- function(x, nm, a = nm, default = NULL) {
  if (is.null(x)) {
    return(default)
  }
  if (is.null(names(x))) {
    return(x)
  }
  k <- intersect(c(nm, a), names(x))
  if (length(k)) x[[k[[1L]]]] else default
}

# One band's `scale`: an offset keyed to a band with no scale of its own
# still applies, at scale 1.
.band_scale <- function(scale, offset, nm, a = nm) {
  .band_value(
    scale,
    nm,
    a,
    default = if (is.null(.band_value(offset, nm, a))) FALSE else 1
  )
}

# Source bands of one table-form asset -> named integer band indices.
# Every band by default; a single-band asset keeps the asset's name, a
# multi-band asset names each band `<asset>_<description>` (or
# `<asset>_b<i>` when descriptions are missing or repeat). `spec` (one
# entry of `bands`) selects indices; its names, where given, replace the
# defaults. Descriptions come from the asset's first item: the GTI
# mosaic does not carry them.
.ds_asset_bands <- function(
  a,
  nb,
  first_item,
  spec,
  call = rlang::caller_env()
) {
  if (is.null(spec)) {
    if (nb == 1L) {
      return(stats::setNames(1L, a))
    }
    idx <- seq_len(nb)
  } else {
    idx <- suppressWarnings(as.integer(spec))
    if (!length(idx) || anyNA(idx) || any(idx < 1L | idx > nb)) {
      cli::cli_abort(
        "{.arg bands} for asset {.val {a}} must index 1..{nb} (it has {nb} band{?s}).",
        call = call
      )
    }
  }
  given <- names(spec) %||% rep("", length(idx))
  nms <- given
  if (!all(nzchar(given))) {
    if (nb == 1L) {
      dflt <- a
    } else {
      ds <- .gdal_handle(first_item)
      d <- vapply(idx, function(b) ds$getDescription(b), "")
      dflt <- ifelse(nzchar(d), d, paste0("b", idx))
      if (anyDuplicated(dflt)) {
        dflt <- paste0("b", idx)
      }
      dflt <- paste0(a, "_", dflt)
    }
    nms <- ifelse(nzchar(given), given, dflt)
  }
  if (anyDuplicated(nms)) {
    cli::cli_abort(
      "{.arg bands} for asset {.val {a}} repeats a band name: {.val {nms[duplicated(nms)]}}.",
      call = call
    )
  }
  stats::setNames(idx, nms)
}

# The sources lazy_dataset() reads for `sources`. A Zarr store's root
# becomes the arrays of one name in it (gdal_zarr_arrays()) that have a CRS
# and extent overlapping `grid`, their rows kept in attribute "zarr_arrays"
# for .zarr_check_placed(). They read as an explicit list of them does, a
# later one winning where two hold data: those in the grid's CRS go last,
# so their own pixels win, the rest in the order of their paths. Anything
# else passes through.
.ds_store_sources <- function(
  sources,
  grid,
  array,
  call = rlang::caller_env()
) {
  err <- c("garry_source_error", "garry_error")
  by_hand <- c(
    "i" = "Or give the arrays as connection strings, such as {.code ZARR:\"<store>\":/<group>/<array>}."
  )
  roots <- vapply(sources, function(s) !is.null(.zarr_store_root(s)), NA)
  if (length(sources) > 1L && any(roots)) {
    where <- .url_scrub(sources[roots][[1L]])
    cli::cli_abort(
      c(
        "{.path {where}} is the root of a Zarr store, which is read alone: give one store's root.",
        by_hand
      ),
      class = err,
      call = call
    )
  }
  if (!any(roots)) {
    if (!is.null(array)) {
      where <- .url_scrub(sources[[1L]])
      cli::cli_abort(
        c(
          "{.arg array} picks arrays of a Zarr store, and {.path {where}} is not a store's root.",
          "i" = "Give the root as a {.file .zarr} path or URL or as {.code ZARR:\"<root>\"}, or drop {.arg array}."
        ),
        class = err,
        call = call
      )
    }
    return(sources)
  }
  if (!is.null(grid)) {
    .assert_class(grid, GridSpec, "GridSpec")
  }
  where <- .url_scrub(sources)
  arrays <- gdal_zarr_arrays(.zarr_store_root(sources), array, call = call)
  if (!is.null(array)) {
    if (identical(arrays$array, "/")) {
      cli::cli_abort(
        c(
          "GDAL opens {.path {where}} as a single array, so {.arg array} has none to pick.",
          "i" = "Drop {.arg array}."
        ),
        class = err,
        call = call
      )
    }
    if (!array %in% arrays$name) {
      cli::cli_abort(
        c(
          "{.path {where}} holds no array named {.val {array}}.",
          "i" = "Its arrays are named {.val {unique(arrays$name)}}."
        ),
        class = err,
        call = call
      )
    }
    arrays <- arrays[arrays$name == array, , drop = FALSE]
  }
  placed <- nzchar(arrays$crs)
  if (!any(placed)) {
    none <- if (nrow(arrays)) {
      "No array of {.path {where}} declares a CRS and extent, and GDAL places none: {.val {arrays$array}}."
    } else {
      "{.path {where}} holds no array of two or more dimensions."
    }
    cli::cli_abort(c(none, by_hand), class = err, call = call)
  }
  nms <- unique(arrays$name[placed])
  if (length(nms) > 1L) {
    cli::cli_abort(
      c(
        "{.path {where}} holds arrays with a CRS and extent under {length(nms)} names: {.val {nms}}.",
        "i" = "Name the one to read with {.arg array}, e.g. {.code array = \"{nms[[1L]]}\"}."
      ),
      class = err,
      call = call
    )
  }
  spatial <- arrays[placed & arrays$name == nms, , drop = FALSE]
  lost <- arrays$array[!placed & arrays$name == nms]
  named <- if (nzchar(nms)) cli::format_inline(" {.val {nms}}") else ""
  n <- nrow(spatial)
  unplaced <- c(
    "!" = if (length(lost)) {
      "{length(lost)} more{named} {cli::qty(length(lost))}array{?s} {?has/have} no CRS or extent, declared or from GDAL: {.val {lost}}."
    }
  )
  if (is.null(grid)) {
    if (n > 1L) {
      cli::cli_abort(
        c(
          "{.path {where}} holds {n}{named} arrays, in {length(unique(spatial$crs))} CRS{?s}.",
          "i" = "Give {.arg grid}: the arrays that overlap it are read onto it."
        ),
        class = err,
        call = call
      )
    }
    keep <- spatial
  } else {
    meets <- vapply(
      seq_len(n),
      function(i) {
        e <- unlist(spatial[i, c("xmin", "ymin", "xmax", "ymax")])
        .gdal_grid_meets(grid, e, spatial$crs[[i]])
      },
      logical(1)
    )
    if (!any(meets)) {
      crs <- .crs_label(grid@crs)
      bb <- .extent_txt(grid@extent)
      cli::cli_abort(
        c(
          "None of the {n}{named} {cli::qty(n)}array{?s} of {.path {where}} overlaps the grid.",
          "i" = "The grid covers {bb} (xmin, ymin, xmax, ymax) in {crs}.",
          unplaced,
          "i" = "Check the grid's CRS and extent, or read another store.",
          by_hand
        ),
        class = err,
        call = call
      )
    }
    keep <- spatial[meets, , drop = FALSE]
    native <- vapply(keep$crs, crs_equal, NA, grid@crs, USE.NAMES = FALSE)
    keep <- keep[order(native), , drop = FALSE]
  }
  if (nrow(arrays) > 1L) {
    cli::cli_inform(c(
      "Reading {nrow(keep)} of the {n}{named} {cli::qty(n)}array{?s} of {.path {where}}: {.val {keep$array}}.",
      unplaced
    ))
  }
  structure(keep$path, zarr_arrays = keep)
}

# File form of lazy_dataset(): one band per (selected) file band, one time
# slice. A vector of paths mosaics first (north-up tiles on one lattice
# of one CRS, gdalbuildvrt); tiles the mosaic cannot hold (south-up, across
# a projection boundary, off that lattice with a `grid` to warp them onto,
# with gaps and no sentinel to mark them, or with a given nodata replacing
# their own) stay a multi-path source node that the warper reads together
# (gdal_warp_window()): band by band, or every band of a window at once
# when the files' bands share storage (one Zarr array per UTM zone). ONE
# metadata probe serves every band (.gdal_handle caches the dataset handle),
# and the probed grid is DECLARED on each band source, so construction costs
# one header fetch however many bands the file carries. Each band is its own
# SourceNode: at collect() the scheduler fans per-band read tasks across the
# reader pool -- N independent handles issuing range requests concurrently,
# the measured fastest remote shape (design/gdal-multiband-fanout.md).
.ds_from_files <- function(
  paths,
  grid,
  assets,
  mask_asset,
  bands,
  resampling,
  nodata,
  scale,
  offset,
  decode = NULL,
  time = NULL
) {
  if (!is.null(assets) && !is.null(bands)) {
    cli::cli_abort(
      "Give {.arg assets} (band names) or {.arg bands} (indices), not both."
    )
  }
  # Prefix bare http(s) with /vsicurl/ HERE, so the stored SourceNode path
  # is GDAL-safe on every seam. The read path (.gdal_handle) prefixes
  # defensively at open, but the warp seam consumes the path directly --
  # an unprefixed remote URL there makes GDAL pull the ENTIRE file (a
  # 2.7 GB AEF tile), observed live 2026-08-12.
  store <- attr(paths, "zarr_arrays") # .ds_store_sources()
  paths <- vapply(as.character(paths), .gdal_href, "", USE.NAMES = FALSE)
  # GDAL must place a store's arrays where the store declares them; the
  # probes serve the checks of several sources below too
  probes <- NULL
  if (any(store$declared)) {
    probes <- .gdal_unplaced_quiet(.source_probes(paths))
    .zarr_check_placed(store, probes)
  }
  meta <- NULL
  path <- if (length(paths) > 1L) {
    probes <- probes %||% .source_probes(paths)
    # Several sources warp together band by band (one Zarr array per UTM
    # zone, say), so they must agree on their bands and, for N-D arrays,
    # on what each band is.
    nbs <- vapply(probes, `[[`, integer(1), "nb")
    if (any(nbs != nbs[[1L]])) {
      cli::cli_abort(c(
        "The sources differ in band count ({.val {unique(nbs)}}).",
        "i" = "Read them separately and combine on a common grid."
      ), class = c("garry_source_error", "garry_error"))
    }
    types <- lapply(probes, `[[`, "types")
    if (length(unique(types)) > 1L) {
      cli::cli_abort(c(
        "The sources differ in band type ({.val {unique(unlist(types))}}).",
        "i" = "Read them separately and combine on a common grid."
      ), class = c("garry_source_error", "garry_error"))
    }
    same_dims <- vapply(
      probes[-1L],
      function(p) identical(p$dims, probes[[1L]]$dims),
      logical(1)
    )
    if (!all(same_dims)) {
      cli::cli_abort(c(
        "The sources' bands carry different dimension coordinates (e.g. years).",
        "i" = "Read them separately and combine on a common grid."
      ), class = c("garry_source_error", "garry_error"))
    }
    # One grid must come from somewhere: without `grid` it is the first
    # source's, and a tile off it would move or change resolution unasked.
    off <- .off_lattice(probes)
    if (is.null(grid) && length(off)) {
      shown <- .url_scrub(paths[c(off[[1L]], 1L)])
      cli::cli_abort(c(
        "{.path {shown[[1L]]}} is not on the pixel lattice of {.path {shown[[2L]]}}: its resolution or origin differs.",
        "i" = "Give {.arg grid} to read the sources onto one grid."
      ), class = c("garry_source_error", "garry_error"))
    }
    if (isTRUE(scale) && length(unique(lapply(probes, `[[`, "affine"))) > 1L) {
      cli::cli_abort(c(
        "The sources declare different band scales or offsets, and {.code scale = TRUE} reads one affine.",
        "i" = "Give {.arg scale} and {.arg offset}, or read them separately."
      ), class = c("garry_source_error", "garry_error"))
    }
    # A Zarr store stays a multi-path source even in one CRS: a mosaic VRT
    # hides the store from every Zarr-specific read path (dimension
    # layout, chunk-sharing collapse, handle budget, single-threaded reads).
    # So do tiles whose sentinel a given nodata replaces: a mosaic's gaps
    # read as that sentinel, which would then be data.
    zarr <- any(vapply(paths, .gdal_is_zarr, logical(1)))
    own <- unlist(lapply(probes, `[[`, "nodata"))
    replaced <- !is.null(nodata) && !all(is.na(own) | own %in% nodata)
    if (!zarr && !replaced && .mosaicable(probes)) {
      gdal_mosaic_vrt(tempfile("garry-mosaic-", fileext = ".vrt"), paths)
    } else {
      meta <- .multi_source_meta(paths, probes)
      paths
    }
  } else {
    paths[[1L]]
  }

  dec <- NULL
  meta_codes <- NULL
  if (!is.null(decode)) {
    if (!isFALSE(scale) || !is.null(offset)) {
      cli::cli_abort(
        "{.arg decode} and {.arg scale}/{.arg offset} do not combine."
      )
    }
    if (!is.null(nodata) && (length(nodata) != 1L || !is.null(names(nodata)))) {
      cli::cli_abort(
        "With {.arg decode}, {.arg nodata} is one code for every band."
      )
    }
    dec <- .decode_prepare(path, decode, nodata)
    meta_codes <- meta %||% gdal_grid_spec(path)
    # one source: its VRT's grid; several: their planning grid, decoded
    meta <- if (length(path) == 1L) {
      gdal_grid_spec(dec$vrt)
    } else {
      utils::modifyList(
        meta_codes,
        list(grid = .grid_retype(meta_codes$grid, "f32"))
      )
    }
    # chunks snap to the codes' blocks, not the VRT's
    meta$block_dim <- meta_codes$block_dim
  }
  if (is.null(meta)) meta <- gdal_grid_spec(path)
  ds <- .gdal_handle(path[[1L]])
  nb <- ds$getRasterCount()
  # An N-D array (time, band, y, x) read through GDAL's classic view: its
  # bands index the band dimension and its slices the time dimension.
  nd <- .nd_layout(.gdal_band_dims(ds))
  if (is.null(nd)) {
    descs <- vapply(seq_len(nb), function(b) ds$getDescription(b), "")
    all_nms <- ifelse(nzchar(descs), descs, paste0("b", seq_len(nb)))
    if (anyDuplicated(all_nms)) {
      all_nms <- paste0("b", seq_len(nb))
    } # degenerate descriptions: index names
    file_bands <- matrix(seq_len(nb))
  } else {
    all_nms <- nd$band_names
    file_bands <- nd$file_bands
    if (!is.null(time)) {
      # build only the selected slices' bands
      keep <- .label_keep(nd$time_labels, time, "t", arg = "time")
      file_bands <- file_bands[, keep, drop = FALSE]
      nd$time_labels <- nd$time_labels[keep]
    }
  }
  if (!is.null(time) && is.null(nd)) {
    where <- .url_scrub(path[[1L]])
    cli::cli_abort(c(
      "{.arg time} selects the slices of an N-D source; {.path {where}} is not read as a (time, band) array.",
      "i" = "Its bands are read as bands; select them with {.arg bands} or {.arg assets}."
    ))
  }
  .check_band_keys(
    list(nodata = nodata, resampling = resampling, scale = scale, offset = offset),
    all_nms
  )
  n_axis <- length(all_nms)

  idx <- if (is.null(bands)) seq_len(n_axis) else bands
  if (
    !is.numeric(idx) || anyNA(idx) || anyDuplicated(idx) ||
      any(idx != round(idx) | idx < 1L | idx > n_axis)
  ) {
    what <- if (is.null(nd)) "file has" else "band dimension has"
    cli::cli_abort("{.arg bands} must index 1..{n_axis} by whole position, each once ({what} {n_axis} band{?s}).")
  }
  nms <- all_nms[idx]
  if (!is.null(assets)) {
    want <- unique(c(assets, mask_asset))
    miss <- setdiff(want, nms)
    if (length(miss)) {
      cli::cli_abort(c(
        "Band name(s) not found in the file: {.val {miss}}.",
        "i" = "Available: {.val {nms}}."
      ))
    }
    keep <- match(want, nms)
    idx <- idx[keep]
    nms <- nms[keep]
  }
  if (length(mask_asset) > 1L || !all(mask_asset %in% nms)) {
    cli::cli_abort("{.arg mask_asset} must name one selected band.")
  }

  # the sentinel file band `b` declares; a node of several sources goes
  # to the warper under one, so those that declare one must share it
  file_nd <- function(b) {
    nd <- if (length(path) > 1L) {
      vapply(probes, function(p) p$nodata[[b]], numeric(1))
    } else {
      ds$getNoDataValue(b)
    }
    nd <- unique(as.numeric(nd[!is.na(nd)]))
    if (length(nd) > 1L) {
      cli::cli_abort(c(
        "The sources declare different nodata for band {b}: {.val {nd}}.",
        "i" = "Give {.arg nodata} to mask one value in all of them, or read them separately."
      ), class = c("garry_source_error", "garry_error"))
    }
    if (length(nd)) nd
  }
  resolve_rs <- function(nm) {
    if (nm %in% mask_asset) "near" else .band_value(resampling, nm, default = "near")
  }

  if (!is.null(grid)) {
    .assert_class(grid, GridSpec, "GridSpec")
  }
  g <- graph_new()
  read_band <- function(b, nm) {
    is_mask <- !is.null(mask_asset) && nm %in% mask_asset
    # a mask band's bits are read as stored: never scaled or decoded
    dec_b <- if (is_mask) NULL else dec
    m <- if (is.null(dec_b) && !is.null(meta_codes)) meta_codes else meta
    # the grid came from band 1; a VRT's bands can differ in type
    bg <- if (is.null(dec_b)) {
      .grid_retype(m$grid, .gdal_band_dtype(ds, b))
    } else {
      m$grid
    }
    # a decoded band's nodata is the VRT's NaN
    nd_b <- if (is.null(dec_b)) .band_value(nodata, nm, default = file_nd(b))
    x <- lazy_source(
      .source_for_nodata(path, ds$getNoDataValue(b), nd_b),
      band = b,
      graph = g,
      grid = bg,
      block_dim = m$block_dim,
      nodata = nd_b,
      decode = dec_b,
      scale = if (is_mask) FALSE else .band_scale(scale, offset, nm),
      offset = .band_value(offset, nm),
      # several sources warp on their planning grid too; one source reads
      # as it is stored there, whatever `resampling` asks of a warp
      resampling = if (length(path) > 1L) resolve_rs(nm) else "near",
      name = nm
    )
    x <- .with_stored(x, .gdal_stored(ds, b))
    if (!is.null(grid)) {
      x <- align_to(x, grid, resampling = resolve_rs(nm))
    }
    x
  }
  layers <- Map(
    function(j, nm) {
      fb <- file_bands[j, ]
      if (is.null(nd)) {
        return(read_band(fb[[1L]], nm))
      }
      stats::setNames(lapply(fb, read_band, nm = nm), nd$time_labels)
    },
    idx,
    nms
  )
  as_dataset(stats::setNames(layers, nms), mask_asset = mask_asset)
}

# Prepare a decode for the 8-bit codes at `path` (lazy_dataset(decode =)):
# `fn` evaluated once on every code of the band type gives the table
# (rounded to f32, NaN at the nodata code), written as a lookup-table
# VRT per source that every read path takes. `nodata` is the code to
# mask: the sources' own, or one given that matches it. Several sources
# (tiles, one Zarr array per UTM zone) share the table and the code.
.decode_prepare <- function(path, fn, nodata = NULL) {
  if (!is.function(fn)) {
    cli::cli_abort(
      "{.arg decode} must be a function of the codes, such as {.fn dequantize_aef}."
    )
  }
  types <- unique(unlist(lapply(path, gdal_band_types)))
  ranges <- list(Byte = c(0L, 255L), Int8 = c(-128L, 127L))
  if (length(types) != 1L || !types %in% names(ranges)) {
    where <- .url_scrub(path[[1L]])
    cli::cli_abort(c(
      "{.arg decode} decodes 8-bit codes; {.path {where}} holds {.val {types}} bands.",
      "i" = "Decode other types with {.fn lazy_map}."
    ))
  }
  r <- ranges[[types]]
  codes <- seq(r[[1L]], r[[2L]])
  # One table serves every band of every source, so they must declare
  # one nodata code (or none): a band's own code is masked on a direct
  # read.
  file_nd <- unique(unlist(lapply(path, gdal_band_nodata)))
  if (length(file_nd) > 1L) {
    cli::cli_abort(c(
      "{.arg decode} needs one nodata code for every band and source; these declare {.val {file_nd}}.",
      "i" = "Decode bands or sources with different codes separately."
    ))
  }
  file_nd <- if (is.na(file_nd)) numeric(0) else file_nd
  if (
    !is.null(nodata) &&
      (length(nodata) != 1L || !is.numeric(nodata) || is.na(nodata))
  ) {
    cli::cli_abort("With {.arg decode}, {.arg nodata} is one code, a number.")
  }
  if (
    !is.null(nodata) &&
      length(file_nd) == 1L &&
      !identical(as.numeric(nodata), file_nd)
  ) {
    cli::cli_abort(c(
      "{.arg nodata} ({nodata}) differs from the file's nodata code ({file_nd}).",
      "i" = "A decoded read masks the file's own code; leave {.arg nodata} unset."
    ))
  }
  nd <- if (is.null(nodata)) file_nd else as.numeric(nodata)
  vals <- fn(as.numeric(codes))
  if (!is.numeric(vals) || length(vals) != length(codes)) {
    cli::cli_abort("{.arg decode} must return one number per code.")
  }
  # the values a Float32 band holds
  table <- readBin(
    writeBin(as.numeric(vals), raw(), size = 4L),
    "numeric",
    length(vals),
    size = 4L
  )
  valid <- !(codes %in% nd)
  if (!all(is.finite(table[valid]))) {
    cli::cli_abort(
      "{.arg decode} must give a finite Float32 value for every code but the nodata code."
    )
  }
  table[!valid] <- NaN
  vrt <- vapply(
    path,
    function(p) {
      gdal_decode_vrt(
        tempfile("garry-decode-", fileext = ".vrt"),
        p,
        r[[1L]],
        table,
        nd
      )
    },
    "",
    USE.NAMES = FALSE
  )
  structure(
    list(vrt = vrt, src = path, lo = r[[1L]], table = table, nodata = nd),
    class = "garry_decode"
  )
}

# The dataset layout of an N-D array's classic view (see .gdal_band_dims()):
# with one time-like dimension and at most one other, a list holding the
# band-axis names (dim values, else b<index>), the time labels (dim
# values, else indices) and `file_bands`, the file band of each
# (band, time) pair. NULL for any other shape, which reads as an ordinary
# multi-band file.
.nd_layout <- function(bd) {
  if (is.null(bd)) {
    return(NULL)
  }
  dims <- attr(bd, "dims")
  is_time <- grepl("^(time|t|date|datetime|year)$", dims, ignore.case = TRUE)
  if (sum(is_time) != 1L || sum(!is_time) > 1L) {
    return(NULL)
  }
  td <- dims[is_time]
  bdim <- dims[!is_time]
  ti <- bd[[paste0(td, "_index")]]
  bi <- if (length(bdim)) bd[[paste0(bdim, "_index")]] else integer(nrow(bd))
  t_lev <- sort(unique(ti))
  b_lev <- sort(unique(bi))
  file_bands <- matrix(NA_integer_, length(b_lev), length(t_lev))
  file_bands[cbind(match(bi, b_lev), match(ti, t_lev))] <- bd$band
  if (anyNA(file_bands)) {
    return(NULL)
  }
  level_names <- function(idx, values, levels, fallback) {
    v <- values[match(levels, idx)]
    if (anyNA(v) || anyDuplicated(v)) fallback else v
  }
  list(
    band_names = if (length(bdim)) {
      level_names(
        bi,
        bd[[paste0(bdim, "_value")]],
        b_lev,
        paste0("b", b_lev + 1L)
      )
    } else {
      "b1"
    },
    time_labels = level_names(
      ti,
      bd[[paste0(td, "_value")]],
      t_lev,
      as.character(t_lev + 1L)
    ),
    file_bands = file_bands
  )
}

#' Assemble a lazy dataset from existing rasters.
#'
#' Each entry of `bands` is either a single `LazyRaster` (one time slice, or an
#' already-reduced composite) or a list of per-slice `LazyRaster`s. Rasters on
#' different graphs are imported into one shared graph.
#'
#' @param bands A named list of `LazyRaster`s or lists of `LazyRaster`s.
#' @param mask_asset Optional name of the QA/mask band within `bands`.
#' @return A `LazyDataset`.
#' @seealso [lazy_dataset()]
#' @export
as_dataset <- function(bands, mask_asset = NULL) {
  if (!is.list(bands) || length(bands) < 1L || is.null(names(bands))) {
    cli::cli_abort("{.arg bands} must be a non-empty named list.")
  }
  norm <- lapply(bands, function(b) {
    if (S7::S7_inherits(b, LazyRaster)) list(b) else as.list(b)
  })
  sp <- NULL
  for (nm in names(norm)) {
    for (lr in norm[[nm]]) {
      if (!S7::S7_inherits(lr, LazyRaster)) {
        cli::cli_abort("band {.val {nm}} must hold {.cls LazyRaster}s.")
      }
      sp <- sp %||% lr@grid
      if (!.spatial_equal(sp, lr@grid)) {
        cli::cli_abort(
          "band {.val {nm}} is not on the first band's grid ({grid_diff(sp, lr@grid)}); {.fn align_to} it first."
        )
      }
    }
  }
  g <- norm[[1L]][[1L]]@graph
  bands2 <- lapply(norm, function(layers) lapply(layers, .ds_reimport, g = g))
  LazyDataset(
    graph = g,
    bands = bands2,
    mask_asset = if (is.null(mask_asset)) {
      character(0)
    } else {
      as.character(mask_asset)
    },
    steps = list(.step("source", "source", detail = max(lengths(bands2))))
  )
}

# ---------------------------------------------------------------------------
# Indexing and print
# ---------------------------------------------------------------------------

# A single band -> LazyRaster: the composite if reduced, else the (t, y, x)
# stack of its slices.
S7::method(`[[`, LazyDataset) <- function(x, i) {
  b <- x@bands[[i]]
  if (is.null(b)) {
    cli::cli_abort("no such band: {.val {i}}")
  }
  if (length(b) == 1L) b[[1L]] else lazy_stack(b, along = "t")
}

# A subset of bands -> a sub-dataset.
S7::method(`[`, LazyDataset) <- function(x, i) {
  sub <- x@bands[.ds_check_bands(x, i)]
  LazyDataset(
    graph = x@graph,
    bands = sub,
    mask_asset = intersect(x@mask_asset, names(sub)),
    steps = x@steps
  )
}

# Split a (t, y, x) raster into its per-slice layers: a stack along t
# gives its inputs back, and an elementwise map over t-stacks is rebuilt
# once per slice over the matching slice of each input. Anything else
# (a reduction, a scan, a focal over the stack) has no per-slice form.
.split_t <- function(x) {
  graph <- x@graph
  memo <- new.env(parent = emptyenv())
  slice_of <- function(id, k) {
    key <- paste(id, k)
    if (!is.null(memo[[key]])) {
      return(memo[[key]])
    }
    n <- .stack_node(graph, id)
    if (!"t" %in% names(n@grid@dims)) {
      return(id) # a 2-D input broadcasts across slices
    }
    out <- if (S7::S7_inherits(n, StackNode) && identical(n@along, "t")) {
      n@parents[[k]]
    } else if (S7::S7_inherits(n, MapNode)) {
      g <- n@grid
      keep <- names(g@dims) != "t"
      # forced before graph_add(), which allocates this node's id first
      parents <- vapply(n@parents, slice_of, integer(1), k = k)
      graph_add(
        graph,
        MapNode,
        parents = parents,
        grid = GridSpec(
          crs = g@crs,
          transform = g@transform,
          extent = g@extent,
          dims = g@dims[keep],
          dtype = g@dtype,
          labels = g@labels[names(g@labels) != "t"]
        ),
        fn = n@fn,
        dtype = n@dtype,
        role = n@role
      )
    } else {
      NA_integer_
    }
    memo[[key]] <- out
    out
  }
  n_t <- x@grid@dims[["t"]]
  ids <- vapply(seq_len(n_t), function(k) slice_of(x@node_id, k), integer(1))
  if (anyNA(ids)) {
    return(NULL)
  }
  layers <- lapply(ids, function(id) {
    LazyRaster(graph = graph, node_id = id, grid = graph_get(graph, id)@grid)
  })
  stats::setNames(layers, x@grid@labels[["t"]])
}

# Assign a derived band into the dataset: `ds[["ndvi"]] <- (nir - red)/(nir + red)`.
# The RHS is a LazyRaster (or a per-slice list) on the dataset's grid; because
# band math like `ds[["B04"]] - ds[["B03"]]` already builds on the shared graph,
# the derivation is part of the dataset's graph and is written by collect().
# Registered as a plain S3 method, not via S7::method(): S7's dynamic
# registration stores the closure itself in the namespace's S3methods table,
# and R < 4.6's `checking replacement functions` calls get() on that entry
# and halts.
#' @rawNamespace S3method("[[<-", "garry::LazyDataset", .lazy_dataset_assign)
.lazy_dataset_assign <- function(x, i, value) {
  if (S7::S7_inherits(value, LazyRaster) && "t" %in% names(value@grid@dims)) {
    # ds[["ndvi"]] <- (ds$nir - ds$red) / (ds$nir + ds$red) on a multi-slice
    # dataset: store per-slice layers like every other band.
    split <- .split_t(value)
    if (is.null(split)) {
      cli::cli_abort(c(
        "assigned band {.val {i}} has a {.val t} axis that cannot be split into slices.",
        "i" = "Assign a list of per-slice {.cls LazyRaster}s instead."
      ))
    }
    value <- split
  } else if (
    S7::S7_inherits(value, LazyRaster) &&
      length(setdiff(names(value@grid@dims), c("x", "y")))
  ) {
    cli::cli_abort(
      "assigned band {.val {i}} has a non-spatial axis; a band holds 2-D layers."
    )
  }
  layers <- if (S7::S7_inherits(value, LazyRaster)) {
    list(value)
  } else if (is.list(value)) {
    value
  } else {
    cli::cli_abort(
      "assigned value must be a {.cls LazyRaster} or a list of them."
    )
  }
  sp <- .ds_grid(x)
  layers <- lapply(layers, function(lr) {
    .assert_class(lr, LazyRaster, "LazyRaster", arg = "value")
    if (!.spatial_equal(sp, lr@grid)) {
      cli::cli_abort("assigned band {.val {i}} is not on the dataset's grid.")
    }
    .ds_reimport(lr, x@graph)
  })
  bands <- x@bands
  bands[[i]] <- layers
  LazyDataset(
    graph = x@graph,
    bands = bands,
    mask_asset = x@mask_asset,
    steps = c(x@steps, list(.step("derive", "derive", detail = i)))
  )
}

# print() cards and plan_draw() live in draw.R.

# ---------------------------------------------------------------------------
# Polymorphic-verb backends (dispatched from lazy_map/focal/reduce_over).
# Non-selected bands pass through unchanged.
# ---------------------------------------------------------------------------

.ds_map <- function(xs, fn, dtype, bands) {
  x <- xs[[1L]]
  if (length(xs) > 1L) {
    cli::cli_abort(c(
      "{.fn lazy_map} over a LazyDataset takes one dataset.",
      "i" = "Extract bands with {.code ds[[\"B04\"]]} for cross-band math."
    ))
  }
  bands <- .ds_check_bands(x, bands)
  sel <- bands %||% .ds_value_bands(x)
  .ds_step(
    x,
    .ds_map_layers(x, sel, function(lr) lazy_map(lr, fn = fn, dtype = dtype)),
    "map",
    paste(sel, collapse = " ")
  )
}

.ds_focal <- function(x, fn, radius, bands) {
  bands <- .ds_check_bands(x, bands)
  sel <- bands %||% .ds_value_bands(x)
  .ds_step(
    x,
    .ds_map_layers(x, sel, function(lr) focal_map(lr, fn = fn, radius = radius)),
    "focal",
    .glue("r={radius} {cli::symbol$bullet %||% '-'} {paste(sel, collapse = ' ')}")
  )
}

.ds_reduce <- function(x, op, over, nan_rm, bands) {
  bands <- .ds_check_bands(x, bands)
  if (identical(over, "band")) {
    # value bands by default: a QA band's codes are not reflectances
    return(reduce_over(
      stack_bands(x[bands %||% .ds_value_bands(x)]),
      op,
      "band",
      nan_rm = nan_rm
    ))
  }
  sel <- bands %||% names(x@bands)
  newbands <- x@bands
  for (a in sel) {
    # Always stack along t (length-1 gives a t dim of 1) so reducing over "t"
    # is well-defined for every op, including a single-slice band.
    lr <- lazy_stack(x@bands[[a]], along = "t")
    newbands[[a]] <- list(reduce_over(lr, op, over, nan_rm = nan_rm))
  }
  .ds_step(
    x,
    newbands,
    "reduce",
    .glue("{if (is.function(op)) 'custom' else op} over {paste(over, collapse = ',')}"),
    mask_asset = intersect(x@mask_asset, names(newbands))
  )
}

.ds_scan <- function(x, fn, over, direction, dtype, bands) {
  if (!identical(over, "t")) {
    cli::cli_abort(c(
      "{.fn scan_over} over a LazyDataset supports {.code over = \"t\"} only.",
      "i" = "Use {.fn stack_bands} + {.fn scan_over} for a band scan."
    ))
  }
  bands <- .ds_check_bands(x, bands)
  sel <- bands %||% .ds_value_bands(x)
  newbands <- x@bands
  for (a in sel) {
    lr <- lazy_stack(x@bands[[a]], along = "t")
    newbands[[a]] <- list(scan_over(
      lr,
      fn,
      over = over,
      direction = direction,
      dtype = dtype
    ))
  }
  .ds_step(
    x,
    newbands,
    "scan",
    .glue("{direction} over {over}"),
    mask_asset = intersect(x@mask_asset, names(newbands))
  )
}

# ---------------------------------------------------------------------------
# Temporal grouping: group_by_time() partitions a dataset's slices into calendar
# groups (month, quarter, year, ...) so a following reduce_over(over = "t")
# builds ONE composite per group -- xarray's resample(time = ...).reduce(). The
# result is a LazyDatasetGroups; collect() materialises each group (a named list,
# or one file per group via a `{group}` path placeholder).
# ---------------------------------------------------------------------------

#' A dataset partitioned into time groups (see [group_by_time()]).
#' @keywords internal
LazyDatasetGroups <- S7::new_class(
  "LazyDatasetGroups",
  properties = list(groups = S7::class_list, by = S7::class_character),
  validator = function(self) {
    if (length(self@groups) < 1L || is.null(names(self@groups))) {
      return("`groups` must be a non-empty named list")
    }
    if (
      !all(vapply(
        self@groups,
        function(g) S7::S7_inherits(g, LazyDataset),
        logical(1)
      ))
    ) {
      return("every group must be a LazyDataset")
    }
    NULL
  }
)

# A labelled t-stack LazyRaster as a one-band ("value") LazyDataset:
# per-slice layers rebuilt from its StackNode parents, named by the t
# labels. This is what lifts the dataset-only time verbs
# (group_by_time) onto bare cubes.
.lr_as_dataset <- function(x) {
  labs <- x@grid@labels[["t"]]
  node <- .stack_node(x@graph, x@node_id)
  if (
    is.null(labs) ||
      !S7::S7_inherits(node, StackNode) ||
      !identical(node@along, "t")
  ) {
    cli::cli_abort(c(
      "grouping a bare raster needs a {.fn lazy_stack} along {.val t} ",
      "with labelled (named) layers.",
      "i" = "name the layers by date, or use a {.cls LazyDataset}"
    ))
  }
  slices <- stats::setNames(
    lapply(node@parents, function(pid) {
      LazyRaster(
        graph = x@graph,
        node_id = pid,
        grid = graph_get(x@graph, pid)@grid
      )
    }),
    labs
  )
  as_dataset(list(value = slices))
}

# Slice name -> group label. Presets truncate the (date) name; a function maps
# the slice name to a label verbatim.
.time_group <- function(slices, by) {
  if (is.function(by)) {
    return(vapply(slices, by, character(1), USE.NAMES = FALSE))
  }
  switch(
    by,
    year = substr(slices, 1L, 4L),
    month = substr(slices, 1L, 7L),
    day = substr(slices, 1L, 10L),
    quarter = {
      d <- .slice_dates(slices)
      .glue(
        "{format(d, '%Y')}-Q{(as.integer(format(d, '%m')) - 1L) %/% 3L + 1L}"
      )
    },
    week = format(.slice_dates(slices), "%G-W%V"),
    cli::cli_abort(
      "unknown {.arg by} {.val {by}}: use year/quarter/month/week/day or a function."
    )
  )
}

.slice_dates <- function(slices) {
  d <- as.Date(slices, format = "%Y-%m-%d")
  if (anyNA(d)) {
    cli::cli_abort(c(
      "{.arg by = \"quarter\"/\"week\"} needs day-granularity (YYYY-MM-DD) slices.",
      "i" = "Build the dataset with {.code granularity = \"day\"}."
    ))
  }
  d
}

#' Group a dataset's time slices into calendar periods.
#'
#' Partitions every band's slices by period so a following
#' `reduce_over(over = "t")` builds one composite per group: a year of daily
#' imagery, `group_by_time("month")`, then a median gives twelve monthly
#' composites (xarray's `resample(time = ...).reduce()`). Slices are grouped by
#' the period prefix of their date name, so build the dataset at
#' `granularity = "day"` and group up from there. Ragged bands are fine -- a
#' band with no slice in a group is simply absent from that group's composite.
#'
#' @param x A `LazyDataset`.
#' @param by `"year"`, `"quarter"`, `"month"` (default), `"week"`, `"day"`, or a
#'   function mapping a slice name to a group label.
#' @return A `LazyDatasetGroups` (a named list of per-group `LazyDataset`s).
#'   Reduce it with [reduce_over()], then [collect()] returns a named list of
#'   results, and [write_tif()] writes one file per group when its `path`
#'   carries a `{group}` placeholder, e.g. `write_tif(x, "ndvi_{group}.tif")`.
#' @export
group_by_time <- function(x, by = "month") {
  # A bare labelled (t,y,x) cube groups too: rebuild the per-slice
  # layers from its StackNode (labels carry the dates) as a one-band
  # dataset, then group as usual.
  if (S7::S7_inherits(x, LazyRaster)) {
    x <- .lr_as_dataset(x)
  }
  .assert_class(x, LazyDataset, "LazyDataset")
  if (!is.function(by)) {
    by <- rlang::arg_match(by, c("year", "quarter", "month", "week", "day"))
  }
  labels <- sort(unique(unlist(
    lapply(x@bands, function(b) .time_group(names(b), by)),
    use.names = FALSE
  )))
  if (!length(labels)) {
    cli::cli_abort("no time groups: are the band slices named by date?")
  }
  lab <- if (is.function(by)) "custom" else by
  groups <- lapply(labels, function(g) {
    nb <- lapply(x@bands, function(b) b[.time_group(names(b), by) == g])
    nb <- nb[lengths(nb) > 0L] # drop bands empty this group
    .ds_step(x, nb, "group", .glue("{lab} = {g}"), mask_asset = intersect(x@mask_asset, names(nb)))
  })
  names(groups) <- labels
  LazyDatasetGroups(groups = groups, by = lab)
}

#' Fill nodata gaps along the time axis.
#'
#' Temporal gap-filling (the verbs xarray spells `ffill`/`bfill`/
#' `interpolate_na`), implemented as [scan_over()] bodies:
#' * `"ffill"` carries the last valid value forward;
#' * `"bfill"` carries the next valid value backward;
#' * `"linear"` interpolates between the nearest valid neighbours
#'   (index-weighted, i.e. by slice position, not calendar spacing),
#'   falling back to ffill/bfill at the ends.
#'
#' Works on a `(t, y, x)` `LazyRaster` cube or per band of a
#' `LazyDataset`. All-nodata pixels stay NaN.
#'
#' @param x A `LazyRaster` with a `t` dim, or a `LazyDataset`.
#' @param method `"ffill"`, `"bfill"` or `"linear"`.
#' @return The filled object, same class as `x`.
#' @family time series smoothers
#' @export
fill_gaps <- function(x, method = c("ffill", "bfill", "linear")) {
  method <- rlang::arg_match(method)
  if (S7::S7_inherits(x, LazyDataset)) {
    newbands <- x@bands
    for (a in setdiff(names(x@bands), x@mask_asset)) {
      if (length(x@bands[[a]]) == 1L) {
        next # a single slice has no gaps to fill along t
      }
      lr <- lazy_stack(x@bands[[a]], along = "t")
      newbands[[a]] <- list(fill_gaps(lr, method))
    }
    return(.ds_step(x, newbands, "fill", method, label = "fill_gaps"))
  }
  .assert_class(x, LazyRaster, "LazyRaster")
  # Carry the last valid value; a NaN carry (init) means "none yet".
  # ScanNode `direction` is declarative metadata: the body itself must
  # run g_scan(reverse=): so the factories bake the direction in.
  carry_body <- function(reverse) {
    force(reverse)
    function(xs, margin) {
      g_scan(
        init = NaN,
        body = function(carry, v) {
          nv <- g_ifelse(g_is_nodata(v), carry, v)
          list(carry = nv, out = nv)
        },
        xs = xs[[1L]],
        reverse = reverse
      )$out
    }
  }
  if (method == "ffill") {
    return(scan_over(x, carry_body(FALSE), over = "t", direction = "forward"))
  }
  if (method == "bfill") {
    return(scan_over(x, carry_body(TRUE), over = "t", direction = "backward"))
  }
  # linear: nearest-valid value and distance in both directions, then a
  # distance-weighted combination per pixel. The zero branch is v * 0
  # (an ARRAY) so the carried distance is array-shaped from step one.
  dist_body <- function(reverse) {
    force(reverse)
    function(xs, margin) {
      g_scan(
        init = 1e30,
        body = function(carry, v) {
          d <- g_ifelse(g_is_nodata(v), carry + 1, v * 0)
          list(carry = d, out = d)
        },
        xs = xs[[1L]],
        reverse = reverse
      )$out
    }
  }
  vf <- scan_over(x, carry_body(FALSE), over = "t", direction = "forward")
  vb <- scan_over(x, carry_body(TRUE), over = "t", direction = "backward")
  df <- scan_over(
    x,
    dist_body(FALSE),
    over = "t",
    direction = "forward",
    dtype = "f32"
  )
  db <- scan_over(
    x,
    dist_body(TRUE),
    over = "t",
    direction = "backward",
    dtype = "f32"
  )
  lazy_map(x, vf, vb, df, db, fn = function(v, f, b, dfv, dbv) {
    interp <- (f * dbv + b * dfv) / (dfv + dbv)
    fill <- g_ifelse(g_is_nodata(f), b, g_ifelse(g_is_nodata(b), f, interp))
    g_ifelse(g_is_nodata(v), fill, v)
  })
}

# reduce_over() dispatch for grouped datasets: reduce each group independently.
.dsg_reduce <- function(x, op, over, nan_rm, bands) {
  LazyDatasetGroups(
    groups = lapply(x@groups, function(g) {
      reduce_over(g, op, over, nan_rm = nan_rm, bands = bands)
    }),
    by = x@by
  )
}

# ---------------------------------------------------------------------------
# stack_bands: assemble the band axis into a single LazyRaster.
# ---------------------------------------------------------------------------

#' Collapse a dataset's bands into a single stacked raster.
#'
#' The dataset -> array operation (xarray's `Dataset.to_dataarray()`): stacks
#' the bands along a new `band` axis. Needs one layer per band, so reduce time
#' first (`reduce_over(ds, "median", "t")`). This is the hook for a reducer
#' over the band axis, such as [band_project()] or [mlp_project()] with
#' `over = "band"`; `collect()` calls it implicitly. A reducer that needs
#' bands and time together, such as [geomedian()], takes a `(band, t, y, x)`
#' cube from `lazy_stack(list(B02 = ds[["B02"]], ...), along = "band")`
#' instead.
#'
#' @param x A `LazyDataset`.
#' @return A `LazyRaster` (the single band if there is one, else a `(band, y, x)`
#'   stack).
#' @export
stack_bands <- function(x) {
  .assert_class(x, LazyDataset, "LazyDataset")
  nl <- lengths(x@bands)
  if (any(nl != 1L)) {
    cli::cli_abort(
      c(
        "{.fn stack_bands} needs one layer per band.",
        "i" = "Reduce time first, e.g. {.code reduce_over(ds, \"median\", \"t\")}.",
        "i" = paste(
          "For a (band, t, y, x) cube, stack the bands with",
          "{.code lazy_stack(list(B02 = ds[[\"B02\"]], ...), along = \"band\")}."
        )
      ),
      class = c("garry_plan_error", "garry_error")
    )
  }
  layers <- lapply(x@bands, function(b) b[[1L]])
  if (length(layers) == 1L) {
    return(layers[[1L]])
  }
  lazy_stack(layers, along = "band")
}

# ---------------------------------------------------------------------------
# Masking
# ---------------------------------------------------------------------------

#' Mask a dataset from a QA band.
#'
#' Derive a bad-pixel mask from a named QA band, optionally clean it with binary
#' morphology, set bad pixels to NaN (nodata) on every value band, and drop the
#' QA band. The mask is a shared subgraph computed once per slice and reused
#' across all value bands.
#'
#' @param x A `LazyDataset`.
#' @param from QA band to derive the mask from; defaults to the dataset's
#'   `mask_asset`.
#' @param where The removal predicate (mask where TRUE). One of:
#'   * a numeric vector -> value membership (bad if the pixel value is in the
#'     set), for categorical QA such as Sentinel-2 SCL,
#'     e.g. `c(0, 1, 2, 3, 8, 9, 10, 11)`;
#'   * [qa_bits()] -> a bitmask test (bad if any listed bit is set), for
#'     packed flags such as HLS Fmask / Landsat QA_PIXEL, e.g. `qa_bits(0:3)`;
#'   * a function `\(f) ...` -> a predicate returning a 0/1 (or logical)
#'     mask, written in the `g_*` vocabulary. A value above 0.5 counts as set,
#'     in `open`/`dilate` as at the end; NaN reads as clear.
#' @param open Opening radius (despeckle): erosion then dilation at this radius,
#'   removing flagged patches too small to hold a disk of that radius. `0`
#'   skips it.
#' @param dilate Dilation radius (buffer): grows the surviving bad regions
#'   outward, a safety margin around clouds. `0` skips it. Applied after `open`.
#' @param join How value and mask slices pair when both carry slice
#'   names that do not fully align: `"exact"` (default) aborts;
#'   `"inner"` pairs on the shared slice names and reports what
#'   dropped.
#' @return A `LazyDataset` with masked value bands.
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' ds <- lazy_dataset(f)
#' # QA values 2 and 8 flag bad pixels
#' masked <- apply_mask(ds, from = "qa", where = c(2, 8))
#' sum(is.nan(collect(masked$red)))
#' @export
apply_mask <- function(
  x,
  from = NULL,
  where,
  open = 0L,
  dilate = 0L,
  join = "exact"
) {
  .assert_class(x, LazyDataset, "LazyDataset")
  open <- .check_radius(open, "open")
  dilate <- .check_radius(dilate, "dilate")
  if (is.null(from)) {
    if (length(x@mask_asset) == 0L) {
      cli::cli_abort(
        "no {.arg from} band given and the dataset has no mask_asset"
      )
    }
    from <- x@mask_asset
  }
  if (length(from) != 1L || !from %in% names(x@bands)) {
    cli::cli_abort("{.arg from} must name one band: {.val {names(x@bands)}}.")
  }
  pred <- .mask_predicate(where)

  masks <- lapply(x@bands[[from]], function(qlr) {
    m <- .with_role(lazy_map(qlr, fn = pred, dtype = "f32"), "mask")
    if (open > 0L) {
      m <- .dilate(.erode(m, open), open)
    }
    if (dilate > 0L) {
      m <- .dilate(m, dilate)
    }
    m
  })

  apply_mask <- function(v, m) {
    # NaN needs a float: an integer band leaves its dtype here
    dt <- .exact_float(v@grid@dtype)
    .with_role(
      lazy_map(
        v,
        m,
        fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, .g_as_declared(vv, dt)),
        dtype = dt
      ),
      "mask"
    )
  }

  newbands <- list()
  for (a in setdiff(names(x@bands), from)) {
    layers <- x@bands[[a]]
    pair <- .ds_align_slices(layers, masks, a, from, join = join)
    # names ride on the pairs: an inner join may drop slices, so
    # names(layers) can no longer be assumed to match.
    nm <- names(pair) %||% names(layers)
    newbands[[a]] <- stats::setNames(
      lapply(pair, function(p) apply_mask(p$v, p$m)),
      nm
    )
  }

  where_desc <- attr(where, "garry_desc") %||%
    if (is.numeric(where)) paste0("values ", .rng(where)) else "predicate"
  morph <- c(
    if (open > 0L) .glue("open {open}"),
    if (dilate > 0L) .glue("dilate {dilate}")
  )
  detail <- paste(
    c(.glue("from {from}"), where_desc, morph),
    collapse = .glue(" {cli::symbol$bullet %||% '-'} ")
  )
  .ds_step(x, newbands, "mask", detail, mask_asset = character(0))
}

# Pair each value-band layer with the mask for its slice, by slice name when
# both are named, else by position (requires equal counts).
.ds_align_slices <- function(layers, masks, band, from, join = "exact") {
  join <- rlang::arg_match0(join, c("exact", "inner"))
  sl <- names(layers)
  named <- !is.null(sl) &&
    all(nzchar(sl)) &&
    !is.null(names(masks)) &&
    all(nzchar(names(masks)))
  if (named && all(sl %in% names(masks))) {
    return(stats::setNames(
      lapply(sl, function(s) list(v = layers[[s]], m = masks[[s]])),
      sl
    ))
  }
  if (named) {
    # Both sides carry slice names but neither covers the other. The
    # old fall-through paired POSITIONALLY when the counts happened to
    # match: silently mispairing dates. Named mismatches now
    # inner-join on the name intersection (join = "inner", reporting
    # what dropped) or abort prescriptively (join = "exact").
    common <- intersect(sl, names(masks))
    if (join == "inner" && length(common)) {
      dropped <- c(setdiff(sl, common), setdiff(names(masks), common))
      if (length(dropped)) {
        cli::cli_inform(paste0(
          "aligning {.val {band}} with {.val {from}} on ",
          "{length(common)} shared slice{?s}; dropped: ",
          "{.val {unique(dropped)}}"
        ))
      }
      return(stats::setNames(
        lapply(common, function(s) list(v = layers[[s]], m = masks[[s]])),
        common
      ))
    }
    cli::cli_abort(c(
      paste0(
        "band {.val {band}} and {.val {from}} carry different ",
        "slice names; slices do not align"
      ),
      "i" = "pass {.code join = \"inner\"} to pair on the shared dates"
    ))
  }
  if (length(layers) != length(masks)) {
    cli::cli_abort(paste0(
      "band {.val {band}} has {length(layers)} slices but mask band ",
      "{.val {from}} has {length(masks)}; slices do not align"
    ))
  }
  Map(function(v, m) list(v = v, m = m), layers, masks)
}

#' Build a QA-bitmask predicate.
#'
#' Returns a predicate `\(f) ...` for [apply_mask()]'s `where` argument that flags a
#' pixel bad when any of the given bits is set. Nodata pixels are treated as
#' clear (matching the QA-fill convention). Use for packed-flag QA bands (HLS
#' Fmask, Landsat QA_PIXEL) where a value list cannot express the test;
#' categorical bands (Sentinel-2 SCL) use a plain value vector instead.
#'
#' @param bits Whole bit positions, 0 to 30, that mark a pixel as bad.
#' @return A predicate function of one array, returning a 0/1 mask:
#'   pass it as [apply_mask()]'s `where`, or apply it directly with
#'   [lazy_map()].
#' @export
qa_bits <- function(bits) {
  if (!is.numeric(bits) || !length(bits) || anyNA(bits) ||
      any(bits != round(bits)) || any(bits < 0 | bits > 30)) {
    cli::cli_abort("{.arg bits} must be whole numbers in 0..30, not {.val {bits}}.")
  }
  bits <- unique(as.integer(bits)) # a repeated bit must not carry into the next
  m <- Reduce(bitwOr, bitwShiftL(1L, bits))
  fn <- function(f) {
    fc <- g_ifelse(g_is_nodata(f), 0, f)
    g_cast(g_bitand(g_cast(fc, "i32"), m) > 0, "f32")
  }
  attr(fn, "garry_desc") <- paste0("bits ", .rng(bits))
  fn
}

# Resolve `where` to a predicate fn(traced array) -> 0/1 f32 mask.
.mask_predicate <- function(where) {
  if (is.function(where)) {
    return(where)
  }
  if (is.numeric(where)) {
    vals <- as.numeric(where)
    return(function(f) {
      ind <- lapply(vals, function(v) g_cast(f == v, "f32"))
      g_cast(Reduce(`+`, ind) > 0, "f32")
    })
  }
  cli::cli_abort(
    "{.arg where} must be a predicate function, a numeric value set, or {.fn qa_bits}"
  )
}

# Binary morphology on a 0/1 mask, disk structuring element: erosion keeps a
# cell where every cell of the disk is set, dilation where any is. A cell is
# set as apply_mask() reads one, `> 0.5`, and NaN compares false, so NaN, which
# is what a window finds past the raster, reads as clear at its own cell and
# goes no further, matching scipy's constant-0 border.
.disk_sel <- function(r) {
  o <- expand.grid(dx = -r:r, dy = -r:r)
  which(o$dx^2 + o$dy^2 <= r^2)
}
.erode <- function(x, r) {
  sel <- .disk_sel(r)
  focal_map(x, radius = as.integer(r), fn = function(sh) {
    g_cast(Reduce(`&`, lapply(sh[sel], function(s) s > 0.5)), "f32")
  })
}
.dilate <- function(x, r) {
  sel <- .disk_sel(r)
  focal_map(x, radius = as.integer(r), fn = function(sh) {
    g_cast(Reduce(`|`, lapply(sh[sel], function(s) s > 0.5)), "f32")
  })
}

# ---------------------------------------------------------------------------
# Arithmetic. A scalar scales/offsets every value band (the mask band, if any,
# is left untouched); two datasets combine band by band (matched by name) and
# slice by slice. Delegates to the LazyRaster operators, so dtype promotion and
# graph merging follow the same rules.
# ---------------------------------------------------------------------------

.ds_scalar_arith <- function(ds, s, op, sym, scalar_first) {
  newbands <- ds@bands
  for (a in .ds_value_bands(ds)) {
    newbands[[a]] <- lapply(ds@bands[[a]], function(lr) {
      if (scalar_first) op(s, lr) else op(lr, s)
    })
  }
  detail <- if (scalar_first) {
    .glue("{s} {sym} bands")
  } else {
    .glue("bands {sym} {s}")
  }
  .ds_step(ds, newbands, "math", detail)
}

.ds_ds_arith <- function(a, b, op, sym) {
  common <- .ds_value_bands(a)
  only <- c(setdiff(common, .ds_value_bands(b)), setdiff(.ds_value_bands(b), common))
  if (length(only) || !length(common)) {
    cli::cli_abort(
      c(
        "datasets must hold the same value bands to combine.",
        "x" = if (length(only)) "Only one of them holds {.val {only}}." else "They hold none.",
        "i" = "Select the bands to combine first: {.code x[bands] {sym} y[bands]}."
      ),
      class = c("garry_source_error", "garry_error")
    )
  }
  newbands <- list()
  for (nm in common) {
    la <- a@bands[[nm]]
    lb <- lapply(b@bands[[nm]], .ds_reimport, g = a@graph)
    pair <- .ds_align_slices(la, lb, nm, nm)
    newbands[[nm]] <- stats::setNames(
      lapply(pair, function(p) op(p$v, p$m)),
      names(la)
    )
  }
  .ds_step(a, newbands, "math", .glue("bands {sym} dataset"), mask_asset = character(0))
}

# Comparisons, ^ and %% ride the same per-slice machinery: `f` here is
# the BASE operator, whose per-slice application dispatches back to the
# LazyRaster method (comparisons -> f32 0/1 masks there).
for (op_name in c(
  "+",
  "-",
  "*",
  "/",
  ">",
  "<",
  ">=",
  "<=",
  "==",
  "!=",
  "^",
  "%%"
)) {
  op_fn <- get(op_name, envir = baseenv())
  S7::method(op_fn, list(LazyDataset, LazyDataset)) <-
    local({
      f <- op_fn
      s <- op_name
      function(e1, e2) .ds_ds_arith(e1, e2, f, s)
    })
  S7::method(op_fn, list(LazyDataset, S7::class_numeric)) <-
    local({
      f <- op_fn
      s <- op_name
      function(e1, e2) .ds_scalar_arith(e1, e2, f, s, FALSE)
    })
  S7::method(op_fn, list(S7::class_numeric, LazyDataset)) <-
    local({
      f <- op_fn
      s <- op_name
      function(e1, e2) .ds_scalar_arith(e2, e1, f, s, TRUE)
    })
}

#' @rawNamespace S3method(Math, "garry::LazyDataset", .lazy_math_dataset)
.lazy_math_dataset <- function(x, ...) .lazy_math(x, .Generic, ...)
