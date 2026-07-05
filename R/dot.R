#' @include plan.R
#' @keywords internal
NULL

#' Render a Plan as DOT (Graphviz) text.
#'
#' @param plan A `Plan`.
#' @return A single DOT string.
#' @export
plan_dot <- function(plan) {
  shape <- c(source_read = "cylinder", compute = "box",
             reduce_partial = "trapezium", reduce_combine = "invtrapezium",
             warp = "parallelogram")
  lines <- c("digraph plan {", "  rankdir=LR;")
  for (s in plan@stages) {
    label <- sprintf("[%d] %s\\nnodes: %s\\nhalo: %d", s@id, s@kind,
                     paste(s@members, collapse = ","), s@halo)
    lines <- c(lines, sprintf("  s%d [shape=%s, label=\"%s\"];",
                              s@id, shape[[s@kind]], label))
  }
  for (s in plan@stages) {
    for (i in s@inputs) {
      lines <- c(lines, sprintf("  s%d -> s%d;", i, s@id))
    }
  }
  lines <- c(lines, sprintf("  s%d [penwidth=2];", plan@sink), "}")
  paste(lines, collapse = "\n")
}
