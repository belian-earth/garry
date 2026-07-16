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
# path and keeps focal morphology on 2D inputs (`.eval_node`'s focal branch is
# 2D). The temporal reduce stacks a band's slices into (t, y, x) and collapses t;
# `collect()`/`stack_bands()` then assemble the band axis. One object at the API
# level; the per-slice layout is an implementation detail.
# ---------------------------------------------------------------------------

#' A named, multi-band, multi-time lazy dataset.
#'
#' The dataset holds one entry per band; each entry is a list of per-time-slice
#' `LazyRaster`s on a shared grid and IR graph. Build one with `lazy_dataset()`
#' (from a STAC source table) or `as_dataset()` (from `LazyRaster`s you already
#' have). Apply `lazy_map()`, `focal()`, `reduce_over()` and `mask()` across all
#' bands; index a single band with `ds[["B04"]]` or a sub-dataset with
#' `ds[c("B04", "B03")]`; `collect()` to materialise.
#'
#' @param graph The shared IR `Graph`.
#' @param bands Named list; each element is a list of per-slice `LazyRaster`s.
#' @param mask_asset Length-0 or length-1 name of the QA/mask band, if any.
#' @param steps Display-only pipeline log (list of `.step()`s), shown by
#'   `draw()`; does not affect execution.
#' @return A `LazyDataset`.
#' @export
LazyDataset <- S7::new_class(
  "LazyDataset",
  properties = list(
    graph      = Graph,
    bands      = S7::class_list,
    mask_asset = S7::class_character,
    steps      = S7::class_list
  ),
  validator = function(self) {
    if (length(self@bands) < 1L || is.null(names(self@bands)))
      return("`bands` must be a non-empty named list")
    if (length(self@mask_asset) > 1L)
      return("`mask_asset` must be length 0 or 1")
    if (length(self@mask_asset) == 1L && !self@mask_asset %in% names(self@bands))
      return("`mask_asset` must name one of `bands`")
    NULL
  }
)

# Spatial grid shared by every band (from the first band's first slice).
.ds_grid <- function(x) x@bands[[1L]][[1L]]@grid

# Value bands are every band except the QA/mask band.
.ds_value_bands <- function(x) setdiff(names(x@bands), x@mask_asset)

# One display step for the pipeline log (see draw()); execution ignores it.
.step <- function(kind, label, detail = NULL) {
  list(kind = kind, label = label, detail = detail)
}

# Format an integer set as compact ranges, e.g. 0:3 -> "0-3",
# c(0,1,2,3,8,9,10,11) -> "0-3, 8-11". Uses an en dash when UTF-8.
.rng <- function(v) {
  v <- sort(unique(as.integer(v)))
  if (!length(v)) return("")
  dash <- if (cli::is_utf8_output()) "\u2013" else "-"
  brk <- c(0L, which(diff(v) != 1L), length(v))
  parts <- vapply(seq_len(length(brk) - 1L), function(i) {
    seg <- v[(brk[i] + 1L):brk[i + 1L]]
    if (length(seg) == 1L) as.character(seg)
    else paste0(seg[1L], dash, seg[length(seg)])
  }, character(1))
  paste(parts, collapse = ", ")
}

# Re-home a LazyRaster onto graph `g` (no-op if already there).
.ds_reimport <- function(lr, g) {
  if (identical(g@nodes, lr@graph@nodes)) return(lr)
  id <- graph_import(g, lr@graph, lr@node_id)
  LazyRaster(graph = g, node_id = id, grid = lr@grid)
}

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

#' Build a lazy dataset from a STAC source table.
#'
#' One band per asset, each a time-sliced GTI mosaic pinned to `grid` (mixed
#' source CRS is fine; the GTI driver reprojects per tile). All bands share one
#' IR graph, so a mask defined once (see `mask()`) is computed once and dedup'd
#' across bands, and `collect()` plans the whole dataset in one pass.
#'
#' @param sources A STAC `doc_items` (from [stac_query()], optionally filtered)
#'   or a `stac_sources()` table.
#' @param grid Target `GridSpec` for every band.
#' @param assets Character vector of value assets to load.
#' @param mask_asset Optional QA/mask asset (e.g. `"Fmask"`, `"SCL"`); loaded
#'   alongside the value assets and used as the default `from` in `mask()`.
#' @param granularity Time-slice granularity (see `stac_time_slices()`).
#' @param sort_field Index field ordering overlaps within a slice.
#' @param nodata Nodata handling: `NULL` (per-asset file metadata), a scalar
#'   (applied to every asset), or a named numeric keyed by asset (unnamed assets
#'   fall back to file metadata). Reflectance and QA bands usually need
#'   different sentinels, so the named form is typical, e.g.
#'   `c(B04 = -9999, B03 = -9999, Fmask = 255)`.
#' @param lon Longitude for `granularity = "solar_day"` (see
#'   `stac_time_slices()`).
#' @param resampling GDAL resampling for the warp-on-read onto `grid`: a scalar
#'   (every value band) or a named character keyed by asset (unnamed assets fall
#'   back to `"near"`). `mask_asset` is always read `"near"` regardless, since
#'   interpolating packed QA bits corrupts them. `"near"` (the default)
#'   preserves exact source values; use `"bilinear"`, `"average"`, `"cubic"`,
#'   ... to interpolate. Resample after the fact instead with [align()].
#' @return A `LazyDataset`.
#' @export
lazy_dataset <- function(sources, grid, assets, mask_asset = NULL,
                         granularity = "day", sort_field = "datetime",
                         nodata = NULL, lon = NULL, resampling = "near") {
  .assert_class(grid, GridSpec, "GridSpec")
  if (length(assets) < 1L)
    cli::cli_abort("{.arg assets} must name at least one asset.")
  all_assets <- unique(c(assets, mask_asset))
  # Accept a STAC `doc_items` directly (the discovery/filter object), converting
  # it to the sources table internally -- so the STAC pipeline stays on the rstac
  # object end to end. A plain data.frame (non-STAC / manual sources) passes
  # through unchanged.
  if (inherits(sources, "doc_items"))
    sources <- stac_sources(sources, assets = all_assets)
  sources <- stac_time_slices(sources, granularity, lon = lon)

  resolve_nodata <- function(a, meta_nodata) {
    file_nd <- if (length(meta_nodata) == 1L) meta_nodata else NULL
    if (is.null(nodata)) return(file_nd)
    if (!is.null(names(nodata)))
      return(if (a %in% names(nodata)) unname(nodata[[a]]) else file_nd)
    as.numeric(nodata)                     # scalar for every asset
  }

  .valid_resampling <- c("near", "bilinear", "cubic", "cubicspline", "lanczos",
                         "average", "rms", "mode", "max", "min", "med",
                         "q1", "q3", "sum")
  if (!all(resampling %in% .valid_resampling))
    cli::cli_abort(c("Invalid {.arg resampling} method{?s}: {.val {setdiff(resampling, .valid_resampling)}}.",
                     "i" = "One of {.val {.valid_resampling}}."))
  resolve_resampling <- function(a) {
    if (!is.null(mask_asset) && a %in% mask_asset) return("near")  # QA never interpolates
    if (is.null(names(resampling))) return(unname(resampling[[1L]]))  # scalar for all
    if (a %in% names(resampling)) unname(resampling[[a]]) else "near"
  }

  graph <- graph_new()
  bands <- list()
  for (a in all_assets) {
    idx  <- stac_gti_index(sources, a, crs = grid@crs)
    meta <- gdal_grid_spec(paste0("GTI:", idx),
                           open_options = gti_open_options(grid))
    nd <- resolve_nodata(a, meta$nodata)
    slices <- sort(unique(sources$slice[sources$asset == a]))
    rs <- resolve_resampling(a)
    layers <- lapply(slices, function(sl) {
      lazy_source(
        paste0("GTI:", idx), graph = graph, nodata = nd,
        open_options = gti_open_options(
          grid, filter = sprintf("slice = '%s'", sl), sort_field = sort_field),
        grid = meta$grid, block_dim = meta$block_dim, resampling = rs)
    })
    names(layers) <- slices
    bands[[a]] <- layers
  }
  bands <- bands[all_assets]               # preserve requested order
  LazyDataset(graph = graph, bands = bands,
              mask_asset = if (is.null(mask_asset)) character(0)
                           else as.character(mask_asset),
              steps = list(.step("source", "source",
                                 detail = max(vapply(bands, length, 1L)))))
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
#' @export
as_dataset <- function(bands, mask_asset = NULL) {
  if (!is.list(bands) || length(bands) < 1L || is.null(names(bands)))
    cli::cli_abort("{.arg bands} must be a non-empty named list.")
  norm <- lapply(bands, function(b) {
    if (S7::S7_inherits(b, LazyRaster)) list(b) else as.list(b)
  })
  g <- norm[[1L]][[1L]]@graph
  bands2 <- lapply(norm, function(layers) lapply(layers, .ds_reimport, g = g))
  LazyDataset(graph = g, bands = bands2,
              mask_asset = if (is.null(mask_asset)) character(0)
                           else as.character(mask_asset),
              steps = list(.step("source", "source",
                                 detail = max(vapply(bands2, length, 1L)))))
}

# ---------------------------------------------------------------------------
# Indexing and print
# ---------------------------------------------------------------------------

# A single band -> LazyRaster: the composite if reduced, else the (t, y, x)
# stack of its slices.
S7::method(`[[`, LazyDataset) <- function(x, i) {
  b <- x@bands[[i]]
  if (is.null(b)) cli::cli_abort("no such band: {.val {i}}")
  if (length(b) == 1L) b[[1L]] else lazy_stack(unname(b), along = "t")
}

# A subset of bands -> a sub-dataset.
S7::method(`[`, LazyDataset) <- function(x, i) {
  sub <- x@bands[i]
  LazyDataset(graph = x@graph, bands = sub,
              mask_asset = intersect(x@mask_asset, names(sub)),
              steps = x@steps)
}

# Assign a derived band into the dataset: `ds[["ndvi"]] <- (nir - red)/(nir + red)`.
# The RHS is a LazyRaster (or a per-slice list) on the dataset's grid; because
# band math like `ds[["B04"]] - ds[["B03"]]` already builds on the shared graph,
# the derivation is part of the dataset's graph and is written by collect().
S7::method(`[[<-`, LazyDataset) <- function(x, i, value) {
  layers <- if (S7::S7_inherits(value, LazyRaster)) list(value)
            else if (is.list(value)) value
            else cli::cli_abort(
              "assigned value must be a {.cls LazyRaster} or a list of them.")
  sp <- .ds_grid(x)
  layers <- lapply(layers, function(lr) {
    .assert_class(lr, LazyRaster, "LazyRaster", arg = "value")
    if (!.spatial_equal(sp, lr@grid))
      cli::cli_abort("assigned band {.val {i}} is not on the dataset's grid.")
    .ds_reimport(lr, x@graph)
  })
  bands <- x@bands
  bands[[i]] <- layers
  LazyDataset(graph = x@graph, bands = bands, mask_asset = x@mask_asset,
              steps = c(x@steps,
                        list(.step("derive", "derive", detail = i))))
}

# print() cards and draw() live in draw.R.

# ---------------------------------------------------------------------------
# Polymorphic-verb backends (dispatched from lazy_map/focal/reduce_over).
# Non-selected bands pass through unchanged.
# ---------------------------------------------------------------------------

.ds_map <- function(xs, fn, dtype, bands) {
  x <- xs[[1L]]
  if (length(xs) > 1L)
    cli::cli_abort(c(
      "{.fn lazy_map} over a LazyDataset takes one dataset.",
      "i" = "Extract bands with {.code ds[[\"B04\"]]} for cross-band math."))
  sel <- bands %||% .ds_value_bands(x)
  newbands <- x@bands
  for (a in sel)
    newbands[[a]] <- lapply(x@bands[[a]],
                            function(lr) lazy_map(lr, fn = fn, dtype = dtype))
  LazyDataset(graph = x@graph, bands = newbands, mask_asset = x@mask_asset,
              steps = c(x@steps, list(.step("map", "map",
                        detail = paste(sel, collapse = " ")))))
}

.ds_focal <- function(x, fn, radius, boundary, bands) {
  sel <- bands %||% .ds_value_bands(x)
  newbands <- x@bands
  for (a in sel)
    newbands[[a]] <- lapply(x@bands[[a]],
                            function(lr) focal(lr, fn = fn, radius = radius,
                                               boundary = boundary))
  LazyDataset(graph = x@graph, bands = newbands, mask_asset = x@mask_asset,
              steps = c(x@steps, list(.step("focal", "focal",
                        detail = sprintf("r=%d %s %s", radius,
                                         cli::symbol$bullet %||% "-",
                                         paste(sel, collapse = " "))))))
}

.ds_reduce <- function(x, op, over, nan_rm, bands) {
  if (identical(over, "band"))
    return(reduce_over(stack_bands(if (is.null(bands)) x else x[bands]),
                       op, "band", nan_rm = nan_rm))
  sel <- bands %||% names(x@bands)
  newbands <- x@bands
  for (a in sel) {
    # Always stack along t (length-1 gives a t dim of 1) so reducing over "t"
    # is well-defined for every op, including a single-slice band.
    lr <- lazy_stack(unname(x@bands[[a]]), along = "t")
    newbands[[a]] <- list(reduce_over(lr, op, over, nan_rm = nan_rm))
  }
  LazyDataset(graph = x@graph, bands = newbands,
              mask_asset = intersect(x@mask_asset, names(newbands)),
              steps = c(x@steps, list(.step("reduce", "reduce",
                        detail = sprintf("%s over %s",
                                 if (is.function(op)) "custom" else op,
                                 paste(over, collapse = ","))))))
}

.ds_scan <- function(x, fn, over, direction, dtype, bands) {
  if (!identical(over, "t"))
    cli::cli_abort(c(
      "{.fn scan_over} over a LazyDataset supports {.code over = \"t\"} only.",
      "i" = "Use {.fn stack_bands} + {.fn scan_over} for a band scan."))
  sel <- bands %||% names(x@bands)
  newbands <- x@bands
  for (a in sel) {
    lr <- lazy_stack(unname(x@bands[[a]]), along = "t")
    newbands[[a]] <- list(scan_over(lr, fn, over = over,
                                    direction = direction, dtype = dtype))
  }
  LazyDataset(graph = x@graph, bands = newbands,
              mask_asset = intersect(x@mask_asset, names(newbands)),
              steps = c(x@steps, list(.step("scan", "scan",
                        detail = sprintf("%s over %s", direction, over)))))
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
    if (length(self@groups) < 1L || is.null(names(self@groups)))
      return("`groups` must be a non-empty named list")
    if (!all(vapply(self@groups, function(g) S7::S7_inherits(g, LazyDataset),
                    logical(1))))
      return("every group must be a LazyDataset")
    NULL
  }
)

# Slice name -> group label. Presets truncate the (date) name; a function maps
# the slice name to a label verbatim.
.time_group <- function(slices, by) {
  if (is.function(by)) return(vapply(slices, by, character(1), USE.NAMES = FALSE))
  switch(by,
    year    = substr(slices, 1L, 4L),
    month   = substr(slices, 1L, 7L),
    day     = substr(slices, 1L, 10L),
    quarter = {
      d <- .slice_dates(slices)
      sprintf("%s-Q%d", format(d, "%Y"),
              (as.integer(format(d, "%m")) - 1L) %/% 3L + 1L)
    },
    week    = format(.slice_dates(slices), "%G-W%V"),
    cli::cli_abort("unknown {.arg by} {.val {by}}: use year/quarter/month/week/day or a function."))
}

.slice_dates <- function(slices) {
  d <- as.Date(slices, format = "%Y-%m-%d")
  if (anyNA(d))
    cli::cli_abort(c("{.arg by = \"quarter\"/\"week\"} needs day-granularity (YYYY-MM-DD) slices.",
                     "i" = "Build the dataset with {.code granularity = \"day\"}."))
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
#'   results (or writes one file per group when `path` carries a `{group}`
#'   placeholder, e.g. `"ndvi_{group}.tif"`).
#' @export
group_by_time <- function(x, by = "month") {
  .assert_class(x, LazyDataset, "LazyDataset")
  if (!is.function(by))
    by <- rlang::arg_match(by, c("year", "quarter", "month", "week", "day"))
  labels <- sort(unique(unlist(
    lapply(x@bands, function(b) .time_group(names(b), by)), use.names = FALSE)))
  if (!length(labels))
    cli::cli_abort("no time groups: are the band slices named by date?")
  lab <- if (is.function(by)) "custom" else by
  groups <- lapply(labels, function(g) {
    nb <- lapply(x@bands, function(b) b[.time_group(names(b), by) == g])
    nb <- nb[vapply(nb, length, integer(1)) > 0L]        # drop bands empty this group
    LazyDataset(graph = x@graph, bands = nb,
                mask_asset = intersect(x@mask_asset, names(nb)),
                steps = c(x@steps, list(.step("group", "group",
                          detail = sprintf("%s = %s", lab, g)))))
  })
  names(groups) <- labels
  LazyDatasetGroups(groups = groups, by = lab)
}

# reduce_over() dispatch for grouped datasets: reduce each group independently.
.dsg_reduce <- function(x, op, over, nan_rm, bands) {
  LazyDatasetGroups(
    groups = lapply(x@groups, function(g)
      reduce_over(g, op, over, nan_rm = nan_rm, bands = bands)),
    by = x@by)
}

# ---------------------------------------------------------------------------
# stack_bands: assemble the band axis into a single LazyRaster.
# ---------------------------------------------------------------------------

#' Collapse a dataset's bands into a single stacked raster.
#'
#' The dataset -> array operation (xarray's `Dataset.to_dataarray()`): stacks
#' the bands along a new `band` axis. Needs one layer per band, so reduce time
#' first (`reduce_over(ds, "median", "t")`). This is the hook for a multiband
#' reducer that must see all bands jointly (e.g. geometric median); `collect()`
#' calls it implicitly.
#'
#' @param x A `LazyDataset`.
#' @return A `LazyRaster` (the single band if there is one, else a `(band, y, x)`
#'   stack).
#' @export
stack_bands <- function(x) {
  .assert_class(x, LazyDataset, "LazyDataset")
  nl <- vapply(x@bands, length, integer(1))
  if (any(nl != 1L))
    cli::cli_abort(c(
      "{.fn stack_bands} needs one layer per band.",
      "i" = "Reduce time first, e.g. {.code reduce_over(ds, \"median\", \"t\")}.",
      "i" = paste("Stacking bands over a time dimension (4D) is not yet",
                  "supported (design/ir-extensions-todo.md #3).")))
  layers <- lapply(x@bands, function(b) b[[1L]])
  if (length(layers) == 1L) return(layers[[1L]])
  lazy_stack(unname(layers), along = "band")
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
#'   * `qa_bits(bits)` -> a bitmask test (bad if any listed bit is set), for
#'     packed flags such as HLS Fmask / Landsat QA_PIXEL, e.g. `qa_bits(0:3)`;
#'   * a function `\(f) ...` -> a raw anvl predicate returning a 0/1 (or logical)
#'     mask.
#' @param open Opening radius (despeckle): erosion then dilation at this radius,
#'   removing isolated flagged pixels up to the radius. `0` skips it.
#' @param dilate Dilation radius (buffer): grows the surviving bad regions
#'   outward, a safety margin around clouds. `0` skips it. Applied after `open`.
#' @param drop Drop the QA band from the returned dataset? (default `TRUE`.)
#' @return A `LazyDataset` with masked value bands.
#' @export
mask <- function(x, from = NULL, where, open = 0L, dilate = 0L, drop = TRUE) {
  .assert_class(x, LazyDataset, "LazyDataset")
  if (is.null(from)) {
    if (length(x@mask_asset) == 0L)
      cli::cli_abort("no {.arg from} band given and the dataset has no mask_asset")
    from <- x@mask_asset
  }
  if (length(from) != 1L || !from %in% names(x@bands))
    cli::cli_abort("{.arg from} must name one band: {.val {names(x@bands)}}.")
  pred <- .mask_predicate(where)

  masks <- lapply(x@bands[[from]], function(qlr) {
    m <- lazy_map(qlr, fn = pred, dtype = "f32")
    if (open   > 0L) m <- .morph_open(m, as.integer(open))
    if (dilate > 0L) m <- .morph_dilate(m, as.integer(dilate))
    m
  })

  apply_mask <- function(v, m)
    lazy_map(v, m, fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, vv),
             dtype = "f32")

  newbands <- list()
  for (a in setdiff(names(x@bands), from)) {
    layers <- x@bands[[a]]
    pair   <- .ds_align_slices(layers, masks, a, from)
    newbands[[a]] <- stats::setNames(
      lapply(pair, function(p) apply_mask(p$v, p$m)), names(layers))
  }
  if (!drop) newbands[[from]] <- x@bands[[from]]

  where_desc <- attr(where, "garry_desc") %||%
    if (is.numeric(where)) paste0("values ", .rng(where)) else "predicate"
  morph <- c(if (open   > 0L) sprintf("open %d", open),
             if (dilate > 0L) sprintf("dilate %d", dilate))
  detail <- paste(c(sprintf("from %s", from), where_desc, morph),
                  collapse = sprintf(" %s ", cli::symbol$bullet %||% "-"))
  LazyDataset(graph = x@graph, bands = newbands,
              mask_asset = if (drop) character(0) else x@mask_asset,
              steps = c(x@steps, list(.step("mask", "mask", detail = detail))))
}

# Pair each value-band layer with the mask for its slice, by slice name when
# both are named, else by position (requires equal counts).
.ds_align_slices <- function(layers, masks, band, from) {
  sl <- names(layers)
  if (!is.null(sl) && !is.null(names(masks)) && all(sl %in% names(masks)))
    return(lapply(sl, function(s) list(v = layers[[s]], m = masks[[s]])))
  if (length(layers) != length(masks))
    cli::cli_abort(paste0(
      "band {.val {band}} has {length(layers)} slices but mask band ",
      "{.val {from}} has {length(masks)}; slices do not align"))
  Map(function(v, m) list(v = v, m = m), layers, masks)
}

#' Build a QA-bitmask predicate.
#'
#' Returns a predicate `\(f) ...` for `mask()`'s `where` argument that flags a
#' pixel bad when any of the given bits is set. Nodata pixels are treated as
#' clear (matching the QA-fill convention). Use for packed-flag QA bands (HLS
#' Fmask, Landsat QA_PIXEL) where a value list cannot express the test;
#' categorical bands (Sentinel-2 SCL) use a plain value vector instead.
#'
#' @param bits Integer bit positions (0-based) that mark a pixel as bad.
#' @return A function of one traced array.
#' @export
qa_bits <- function(bits) {
  m <- as.integer(sum(2^as.integer(bits)))
  fn <- function(f) {
    fc <- g_ifelse(g_is_nodata(f), 0, f)
    g_cast(g_bitand(g_cast(fc, "i32"), m) > 0, "f32")
  }
  attr(fn, "garry_desc") <- paste0("bits ", .rng(bits))
  fn
}

# Resolve `where` to a predicate fn(traced array) -> 0/1 f32 mask.
.mask_predicate <- function(where) {
  if (is.function(where)) return(where)
  if (is.numeric(where)) {
    vals <- as.numeric(where)
    return(function(f) {
      ind <- lapply(vals, function(v) g_cast(f == v, "f32"))
      g_cast(Reduce(`+`, ind) > 0, "f32")
    })
  }
  cli::cli_abort(
    "{.arg where} must be a predicate function, a numeric value set, or {.fn qa_bits}")
}

# Binary morphology on a 0/1 mask, disk structuring element. Erosion of a 0/1
# mask is the product over the disk offsets; dilation is its dual. NaN (beyond-
# edge halo pad) propagates and reads as clear in mask()'s final ifelse,
# matching scipy's constant-0 border.
.disk_sel <- function(r) {
  o <- expand.grid(dx = -r:r, dy = -r:r)
  which(o$dx^2 + o$dy^2 <= r^2)
}
.erode <- function(x, r) {
  sel <- .disk_sel(r)
  focal(x, radius = as.integer(r), fn = function(sh) Reduce(`*`, sh[sel]))
}
.dilate <- function(x, r) {
  sel <- .disk_sel(r)
  focal(x, radius = as.integer(r), fn = function(sh)
    1 - Reduce(`*`, lapply(sh[sel], function(s) 1 - s)))
}
.morph_open   <- function(x, r) .dilate(.erode(x, r), r)
.morph_dilate <- function(x, r) .dilate(x, r)

# ---------------------------------------------------------------------------
# Arithmetic. A scalar scales/offsets every value band (the mask band, if any,
# is left untouched); two datasets combine band by band (matched by name) and
# slice by slice. Delegates to the LazyRaster operators, so dtype promotion and
# graph merging follow the same rules.
# ---------------------------------------------------------------------------

.ds_scalar_arith <- function(ds, s, op, sym, scalar_first) {
  newbands <- ds@bands
  for (a in .ds_value_bands(ds))
    newbands[[a]] <- lapply(ds@bands[[a]], function(lr)
      if (scalar_first) op(s, lr) else op(lr, s))
  detail <- if (scalar_first) sprintf("%s %s bands", s, sym)
            else sprintf("bands %s %s", sym, s)
  LazyDataset(graph = ds@graph, bands = newbands, mask_asset = ds@mask_asset,
              steps = c(ds@steps, list(.step("math", "math", detail = detail))))
}

.ds_ds_arith <- function(a, b, op, sym) {
  common <- intersect(.ds_value_bands(a), .ds_value_bands(b))
  if (length(common) == 0L)
    cli::cli_abort("datasets share no value bands to combine")
  newbands <- list()
  for (nm in common) {
    la <- a@bands[[nm]]
    lb <- lapply(b@bands[[nm]], .ds_reimport, g = a@graph)
    pair <- .ds_align_slices(la, lb, nm, nm)
    newbands[[nm]] <- stats::setNames(
      lapply(pair, function(p) op(p$v, p$m)), names(la))
  }
  LazyDataset(graph = a@graph, bands = newbands, mask_asset = character(0),
              steps = c(a@steps, list(.step("math", "math",
                        detail = sprintf("bands %s dataset", sym)))))
}

for (op_name in c("+", "-", "*", "/")) {
  op_fn <- get(op_name, envir = baseenv())
  S7::method(op_fn, list(LazyDataset, LazyDataset)) <-
    local({ f <- op_fn; s <- op_name; function(e1, e2) .ds_ds_arith(e1, e2, f, s) })
  S7::method(op_fn, list(LazyDataset, S7::class_numeric)) <-
    local({ f <- op_fn; s <- op_name; function(e1, e2) .ds_scalar_arith(e1, e2, f, s, FALSE) })
  S7::method(op_fn, list(S7::class_numeric, LazyDataset)) <-
    local({ f <- op_fn; s <- op_name; function(e1, e2) .ds_scalar_arith(e2, e1, f, s, TRUE) })
}
