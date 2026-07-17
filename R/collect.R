#' @include passes.R
#' @keywords internal
NULL

#' Materialise a LazyRaster (or inspect its plan).
#'
#' `plan_only = TRUE` runs the planner passes and returns the `Plan`
#' without executing: the permanent introspection path. Execution
#' arrives in Phase 5.
#'
#' @param x A `LazyRaster`, or a `LazyDataset` (its bands are assembled along the
#'   band axis via `stack_bands()` first).
#' @param plan_only Return the `Plan` instead of executing?
#' @param path Optional GTiff destination; the result is written chunk
#'   by chunk and the path returned invisibly.
#' @param nodata Optional sentinel for the written file (NaN demotes to
#'   it; required for integer outputs containing nodata).
#' @param distributed Execute across the [garry_daemons()] pools? Defaults to
#'   [garry_daemons_set()], so `collect(x)` uses the pools when they are running
#'   and runs single-threaded otherwise. Pass `TRUE`/`FALSE` to override; the
#'   distributed result is identical to the single-threaded one.
#' @return With `plan_only = TRUE`, the `Plan`. With `path`, the path,
#'   invisibly. Otherwise the materialised result in the R raster convention
#'   (spatial-first, layer-last): a scalar for global reductions, a `[y, x]`
#'   matrix for a single layer, or a `(y, x, band)` array for multiple bands
#'   (matching `terra::as.array()`; plots directly with `rasterImage`/`ximage`).
#'   A matrix/array result also carries a `gis` attribute in the style of
#'   `gdalraster::read_ds()` (`type`, `bbox` = `c(xmin, ymin, xmax, ymax)`,
#'   `dim` = `c(nx, ny, nbands)`, `srs` = WKT, `datatype`), so the array is
#'   self-describing and [preview()] can set real-world axes without the grid.
#' @export
collect <- function(x, plan_only = FALSE, path = NULL, nodata = NULL,
                    distributed = garry_daemons_set()) {
  # A grouped dataset materialises one result per time group (see
  # group_by_time()): a named list, or one file per group when `path` carries a
  # `{group}` placeholder.
  if (S7::S7_inherits(x, LazyDatasetGroups))
    return(.collect_groups(x, plan_only, path, nodata, distributed))
  # A dataset's band names become the output band descriptions; capture them
  # before stack_bands() collapses the named bands into one node.
  band_names <- NULL
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
    if (distributed)
      cli::cli_inform("multi-export collect runs single-process in v1")
    ck <- .ck_resolve(p)
    p <- ck$plan
    if (!is.null(ck$root)) on.exit(unlink(ck$root, recursive = TRUE), add = TRUE)
    res <- execute_plan(p, path = path, nodata = nodata)
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
  # lazy_cog sources ("CK:") fetch nothing until here: resolve each source set to
  # a staged grid-aligned raster once (single-band sets through one concurrent
  # ck_batch pool), then the executors read it as an ordinary GDAL source.
  ck <- .ck_resolve(p)
  p <- ck$plan
  if (!is.null(ck$root)) on.exit(unlink(ck$root, recursive = TRUE), add = TRUE)
  res <- if (distributed) {
    if (!garry_daemons_set())
      cli::cli_abort(c(
        "{.arg distributed} is TRUE but no garry daemon pools are running.",
        "i" = "Call {.fn garry_daemons} first, or pass {.code distributed = FALSE}."))
    spec <- .cd_spec(p)               # pure composite fast path (fetch-ordered pipeline)
    decomp <- if (is.null(spec)) .gd_decompose(p) else NULL   # reduce-decomposition
    if (!is.null(spec))
      .execute_composite_direct(p, spec, path = path, nodata = nodata,
                                band_names = band_names)
    else if (!is.null(decomp))
      # Any reduce-structured graph (ndvi, nested reduce->map->reduce, focal over
      # a composite): overlap-compute the leaf reduces, run the upper IR on them.
      .execute_gd_reduce(p, decomp, path = path, nodata = nodata,
                         band_names = band_names)
    else
      execute_plan_mirai(p, path = path, nodata = nodata, band_names = band_names)
  } else {
    execute_plan(p, path = path, nodata = nodata, band_names = band_names)
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

# Materialise each time group of a LazyDatasetGroups. With `path`, writes one
# file per group (a `{group}` placeholder is substituted, else the group label
# is inserted before the extension) and returns the paths invisibly; otherwise
# returns a named list of results (or Plans when `plan_only`).
.collect_groups <- function(x, plan_only, path, nodata, distributed) {
  labels <- names(x@groups)
  paths <- if (is.null(path)) NULL else .group_paths(path, labels)
  res <- lapply(seq_along(x@groups), function(i)
    collect(x@groups[[i]], plan_only = plan_only,
            path = if (is.null(paths)) NULL else paths[[i]],
            nodata = nodata, distributed = distributed))
  names(res) <- labels
  if (!is.null(path) && !plan_only) return(invisible(stats::setNames(unlist(paths), labels)))
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
    if (nzchar(ext)) sprintf("%s_%s.%s", stem, s, ext) else sprintf("%s_%s", stem, s),
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
