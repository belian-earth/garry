#' @include passes.R
#' @keywords internal
NULL

#' Materialise a LazyRaster (or inspect its plan).
#'
#' `plan_only = TRUE` runs the planner passes and returns the `Plan`
#' without executing: the permanent introspection path. Execution
#' arrives in Phase 5.
#'
#' @param x A `LazyRaster`.
#' @param plan_only Return the `Plan` instead of executing?
#' @param path Optional GTiff destination; the result is written chunk
#'   by chunk and the path returned invisibly.
#' @param nodata Optional sentinel for the written file (NaN demotes to
#'   it; required for integer outputs containing nodata).
#' @return With `plan_only = TRUE`, the `Plan`. With `path`, the path,
#'   invisibly. Otherwise the materialised result: a `[y, x]` matrix
#'   for raster sinks, a scalar for global reductions.
#' @export
collect <- function(x, plan_only = FALSE, path = NULL, nodata = NULL) {
  p <- plan_lazy(x)
  if (plan_only) return(p)
  execute_plan(p, path = path, nodata = nodata)
}
