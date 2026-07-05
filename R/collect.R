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
#' @return A `Plan` (for now; executed results from Phase 5).
#' @export
collect <- function(x, plan_only = FALSE) {
  p <- plan_lazy(x)
  if (plan_only) return(p)
  .garry_error("execution arrives in Phase 5; use collect(x, plan_only = TRUE)",
               "garry_not_implemented_error")
}
