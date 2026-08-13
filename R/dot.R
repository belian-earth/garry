#' @include plan.R
#' @keywords internal
NULL

#' Render a Plan as DOT (Graphviz) text.
#'
#' A `Plan` is obtained from [plan_lazy()].
#'
#' @param plan A `Plan`, from [plan_lazy()].
#' @return A single DOT string.
#' @seealso [draw()], the user-facing pipeline visualisation.
#' @export
plan_dot <- function(plan) {
  shape <- c(
    source_read = "cylinder",
    compute = "box",
    reduce_partial = "trapezium",
    reduce_combine = "invtrapezium",
    warp = "parallelogram"
  )
  lines <- c("digraph plan {", "  rankdir=LR;")
  for (s in plan@stages) {
    label <- .glue(
      "[{s@id}] {s@kind}\\nnodes: ",
      "{paste(s@members, collapse = ',')}\\nhalo: {s@halo}"
    )
    lines <- c(
      lines,
      .glue("  s{s@id} [shape={shape[[s@kind]]}, label=\"{label}\"];")
    )
  }
  for (s in plan@stages) {
    for (i in s@inputs) {
      lines <- c(lines, .glue("  s{i} -> s{s@id};"))
    }
  }
  lines <- c(lines, .glue("  s{plan@sink} [penwidth=2];"), "}")
  paste(lines, collapse = "\n")
}
