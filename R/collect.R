#' @include passes.R
#' @keywords internal
NULL

#' Materialise a LazyRaster (or inspect its plan).
#'
#' Executes the plan and returns the result in the R session, always.
#' To stream the result to a file instead, use [write_tif()]; to
#' checkpoint to local cubes and stay lazy, use [materialise()].
#' `plan_only = TRUE` runs the planner passes and returns the `Plan`
#' without executing, for inspection.
#'
#' @param x A `LazyRaster`, a `LazyDataset` (its bands are assembled along
#'   the band axis via `stack_bands()` first), a named list of lazy rasters
#'   (multi-export: one plan, a named list of results), or a
#'   `LazyDatasetGroups` (one result per group).
#' @param plan_only Return the `Plan` instead of executing?
#' @param distributed Execute across the [garry_daemons()] pools? Defaults to
#'   [garry_daemons_set()], so `collect(x)` uses the pools when they are running
#'   and runs single-threaded otherwise. Pass `TRUE`/`FALSE` to override; the
#'   distributed result is identical to the single-threaded one.
#' @return With `plan_only = TRUE`, the `Plan`. Otherwise the materialised
#'   result in the R raster convention (spatial-first, layer-last): a scalar
#'   for global reductions, a `[y, x]` matrix for a single layer, or a
#'   `(y, x, band)` array for multiple bands
#'   (matching `terra::as.array()`; plots directly with `rasterImage`/`ximage`).
#'   A matrix/array result also carries a `gis` attribute in the style of
#'   `gdalraster::read_ds()` (`type`, `bbox` = `c(xmin, ymin, xmax, ymax)`,
#'   `dim` = `c(nx, ny, nbands)`, `srs` = WKT, `datatype`), so the array is
#'   self-describing and [preview()] can set real-world axes without the grid.
#' @export
collect <- function(x, plan_only = FALSE,
                    distributed = garry_daemons_set()) {
  .collect_impl(x, plan_only = plan_only, distributed = distributed)
}

# The execution engine behind collect()/write_tif()/materialise().
# `wspec` (write_tif) is the sink write spec: list(dtype, scale, offset),
# applied at the sink boundary by the executors.
.collect_impl <- function(x, plan_only = FALSE, path = NULL, nodata = NULL,
                          distributed = garry_daemons_set(),
                          band_names = NULL, wspec = NULL) {
  .garry_opt_check()
  # A grouped dataset materialises one result per time group (see
  # group_by_time()): a named list, or one file per group when `path` carries a
  # `{group}` placeholder.
  if (S7::S7_inherits(x, LazyDatasetGroups))
    return(.collect_groups(x, plan_only, path, nodata, distributed, wspec))
  # A dataset's band names become the output band descriptions; capture them
  # before stack_bands() collapses the named bands into one node.
  if (S7::S7_inherits(x, LazyDataset)) {
    band_names <- names(x@bands)
    x <- stack_bands(x)
  }
  p <- plan_lazy(x)
  if (plan_only) return(p)
  # Multi-export v1 (design/multi-export-collect.md): several sinks share
  # ONE single-threaded execution; the distributed scheduler learns
  # multi-sink next.
  if (length(p@sinks) > 1L) {
    .garry_state$route <- if (distributed) "scheduler" else "single"
    res <- if (distributed) {
      execute_plan_mirai(p, path = path, nodata = nodata,
                         band_names = band_names, wspec = wspec)
    } else {
      execute_plan(p, path = path, nodata = nodata,
                   band_names = band_names, wspec = wspec)
    }
    if (!is.null(path)) return(invisible(res))
    # per-sink: same layout + gis attribute as a single-sink collect
    return(lapply(stats::setNames(seq_along(res), names(res)), function(k) {
      out <- .collect_layout(res[[k]])
      if (!is.null(dim(out))) {
        grid <- graph_get(p@graph, p@sinks[[k]])@grid
        nb <- if (length(dim(out)) == 3L) dim(out)[[3L]] else 1L
        attr(out, "gis") <- .gis_attr(grid, nb)
      }
      out
    }))
  }
  # Labelled output: a bare (t,y,x) / (band,y,x) result inherits its
  # axis labels (GridSpec labels, carried from lazy_stack layer names)
  # as output band descriptions unless the dataset already supplied
  # band names.
  band_names <- band_names %||% .grid_layer_labels(p@stages[[p@sink]]@grid)
  res <- if (distributed) {
    if (!garry_daemons_set())
      cli::cli_abort(c(
        "{.arg distributed} is TRUE but no garry daemon pools are running.",
        "i" = "Call {.fn garry_daemons} first, or pass {.code distributed = FALSE}."))
    # Quantized writes (wspec with scale) bypass the cd/gd fast paths:
    # their band kernels do not yet fold g_quantize, and the one-
    # device-quantizer invariant (byte-identical digital numbers on
    # every route) is worth more than the fast path here. Folding wq
    # into the cd/gd kernels is the follow-up (ir-extensions-todo #12).
    quantizing <- !is.null(wspec) && length(wspec$scale) == 1L
    spec <- if (quantizing) NULL else .cd_spec(p)  # composite fast path
    decomp <- if (is.null(spec) && !quantizing) .gd_decompose(p) else NULL
    # Record which route ran (garry_last_route()): the selection is
    # silent, and a plan silently changing route is exactly the
    # regression class the equivalence suite must be able to observe.
    .garry_state$route <- if (!is.null(spec)) "composite_direct"
      else if (!is.null(decomp)) "gd_reduce"
      else "scheduler"
    if (!is.null(spec))
      .execute_composite_direct(p, spec, path = path, nodata = nodata,
                                band_names = band_names, wspec = wspec)
    else if (!is.null(decomp))
      # Any reduce-structured graph (ndvi, nested reduce->map->reduce, focal over
      # a composite): overlap-compute the leaf reduces, run the upper IR on them.
      .execute_gd_reduce(p, decomp, path = path, nodata = nodata,
                         band_names = band_names, wspec = wspec)
    else
      execute_plan_mirai(p, path = path, nodata = nodata,
                         band_names = band_names, wspec = wspec)
  } else {
    .garry_state$route <- "single"
    execute_plan(p, path = path, nodata = nodata, band_names = band_names,
                 wspec = wspec)
  }
  if (!is.null(path)) return(invisible(res))
  out <- .collect_layout(res)
  # Self-describing result: a gdalraster read_ds()-style `gis` attribute from the
  # plan's output grid. Only for rasters (matrix/array) -- a scalar global
  # reduction is not spatial. preview() reads it for real-world axes.
  if (!is.null(dim(out))) {
    grid <- p@stages[[p@sink]]@grid
    nb <- if (length(dim(out)) == 3L) dim(out)[[3L]] else 1L
    attr(out, "gis") <- .gis_attr(grid, nb)
  }
  out
}

#' Convert a collected result to a terra SpatRaster.
#'
#' `collect()` results carry a `gis` attribute (bbox, CRS, dims); this
#' wraps the array as a `terra::SpatRaster` for hand-off to the terra
#' ecosystem (plotting, zonal statistics, vector ops). Band
#' names/descriptions are preserved when present.
#'
#' @param x A matrix or `(y, x, band)` array from [collect()] (must
#'   carry the `gis` attribute).
#' @return A `terra::SpatRaster`.
#' @export
as_terra <- function(x) {
  rlang::check_installed("terra", reason = "for as_terra().")
  gis <- attr(x, "gis")
  if (is.null(gis))
    cli::cli_abort(paste0(
      "{.arg x} has no {.code gis} attribute; pass an in-memory ",
      "{.fn collect} result (matrix or (y, x, band) array)"))
  a <- if (length(dim(x)) == 2L) array(x, c(dim(x), 1L)) else unclass(x)
  attr(a, "gis") <- NULL
  r <- terra::rast(a, crs = gis$srs,
                   extent = terra::ext(gis$bbox[[1L]], gis$bbox[[3L]],
                                       gis$bbox[[2L]], gis$bbox[[4L]]))
  nms <- dimnames(x)[[3L]]
  if (!is.null(nms)) names(r) <- nms
  r
}

#' Which execution route did the last `collect()` take?
#'
#' A diagnostics helper. The distributed `collect()` picks its execution
#' route automatically, and this reports the route the last call took,
#' so pipelines can log it or assert a plan has not changed route.
#' The values are:
#'
#' - `"composite_direct"`: the specialised masked-composite executor;
#' - `"gd_reduce"`: the general reduce-decomposition executor;
#' - `"scheduler"`: the general distributed scheduler;
#' - `"single"`: the in-process single-threaded executor
#'   (`distributed = FALSE`).
#'
#' @return `"composite_direct"`, `"gd_reduce"`, `"scheduler"` or
#'   `"single"`; `NULL` before any `collect()` in the session.
#' @export
garry_last_route <- function() .garry_state$route

# Materialise each time group of a LazyDatasetGroups. With `path`, writes one
# file per group (a `{group}` placeholder is substituted, else the group label
# is inserted before the extension) and returns the paths invisibly; otherwise
# returns a named list of results (or Plans when `plan_only`).
.collect_groups <- function(x, plan_only, path, nodata, distributed,
                            wspec = NULL) {
  labels <- names(x@groups)
  paths <- if (is.null(path)) NULL else stats::setNames(unlist(.group_paths(path, labels)), labels)
  # Multi-export route (design/multi-export-collect.md): ONE plan whose
  # sinks are the per-group band stacks, so every group's reads enter
  # one ready queue and drain together under fetch-first priority.
  # The per-group loop pulsed the network instead: one fetch burst,
  # then an idle assemble/compute/write trough, per group
  # (ir-extensions-todo.md #5). plan_only keeps the loop: callers
  # expect one inspectable Plan per group.
  if (!plan_only && length(x@groups) > 1L) {
    sinks <- stats::setNames(lapply(x@groups, stack_bands), labels)
    bn <- stats::setNames(lapply(x@groups, function(g) names(g@bands)),
                          labels)
    res <- .collect_impl(sinks, path = paths, nodata = nodata,
                         distributed = distributed, band_names = bn,
                         wspec = wspec)
    if (!is.null(path)) return(invisible(paths))
    return(res)
  }
  res <- lapply(seq_along(x@groups), function(i)
    .collect_impl(x@groups[[i]], plan_only = plan_only,
                  path = if (is.null(paths)) NULL else paths[[i]],
                  nodata = nodata, distributed = distributed, wspec = wspec))
  names(res) <- labels
  if (!is.null(path) && !plan_only) return(invisible(paths))
  res
}

# One output path per group: substitute a `{group}`/`{time}` placeholder, or
# insert the (filesystem-safe) group label before the file extension.
.group_paths <- function(path, labels) {
  safe <- gsub("[^A-Za-z0-9._-]", "-", labels)
  if (grepl("\\{group\\}|\\{time\\}", path))
    return(vapply(safe, function(s) gsub("\\{group\\}|\\{time\\}", s, path),
                  character(1), USE.NAMES = FALSE))
  ext <- tools::file_ext(path); stem <- tools::file_path_sans_ext(path)
  vapply(safe, function(s)
    if (nzchar(ext)) .glue("{stem}_{s}.{ext}") else .glue("{stem}_{s}"),
    character(1), USE.NAMES = FALSE)
}

# gdalraster read_ds()-style `gis` attribute from a GridSpec: type, bbox
# (xmin,ymin,xmax,ymax), dim (nx,ny,nbands), srs (WKT), datatype (GDAL name).
.gis_attr <- function(grid, nbands) {
  list(
    type = "raster",
    bbox = as.numeric(grid@extent),
    dim = c(unname(grid@dims[["x"]]), unname(grid@dims[["y"]]), as.integer(nbands)),
    srs = .canon_crs(grid@crs),
    datatype = unname(.gdal_dtype_rev[[grid@dtype]] %||% grid@dtype)
  )
}

# Normalise an in-memory collect() result to the R raster convention:
# spatial-first, layer-last. A scalar reduction stays a scalar; a 2D result
# stays a [y, x] matrix; a multiband/multitemporal result becomes (y, x, band)
# so it matches terra::as.array() and plots directly (rasterImage / ximage).
# Internals stay band-first ((band/t, y, x), decision D17); this permutes only
# at the user boundary. The composite path hands back a list of [y, x] matrices;
# the scheduler a (band, y, x) array.
.collect_layout <- function(res) {
  if (is.list(res))
    return(if (length(res) == 1L) res[[1L]] else simplify2array(res))
  if (is.array(res) && length(dim(res)) == 3L) return(aperm(res, c(2L, 3L, 1L)))
  res
}
