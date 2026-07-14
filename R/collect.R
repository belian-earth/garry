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
#'   invisibly. Otherwise the materialised result: a `[y, x]` matrix
#'   for raster sinks, a scalar for global reductions.
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
  if (distributed) {
    if (!garry_daemons_set())
      cli::cli_abort(c(
        "{.arg distributed} is TRUE but no garry daemon pools are running.",
        "i" = "Call {.fn garry_daemons} first, or pass {.code distributed = FALSE}."))
    spec <- .cd_spec(p)               # GDAL-direct composite fast path
    if (!is.null(spec))
      return(.execute_composite_direct(p, spec, path = path, nodata = nodata,
                                       band_names = band_names))
    return(execute_plan_mirai(p, path = path, nodata = nodata,
                              band_names = band_names))
  }
  execute_plan(p, path = path, nodata = nodata, band_names = band_names)
}
