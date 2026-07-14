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
#' @export
collect <- function(x, plan_only = FALSE, path = NULL, nodata = NULL,
                    distributed = garry_daemons_set()) {
  # A dataset's band names become the output band descriptions; capture them
  # before stack_bands() collapses the named bands into one node.
  band_names <- NULL
  if (S7::S7_inherits(x, LazyDataset)) {
    band_names <- names(x@bands)
    x <- stack_bands(x)
  }
  p <- plan_lazy(x)
  if (plan_only) return(p)
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
  .collect_layout(res)
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
