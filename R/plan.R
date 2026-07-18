#' @include grid.R chunk_grid.R graph.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Plan and Stage: the planner's output (decision D10).
#
# A Stage is one schedulable unit: a set of composed IR nodes, ONE closure
# built from the garry op vocabulary, a halo, a chunk grid, and its input
# stages. The same closure runs under the pure-R oracle (Phase 3 tests)
# and under anvl jit() (Phase 5) — that equivalence is the point.
#
# Calling conventions by kind:
# - "source_read":    fn is identity; the executor reads the (halo-padded)
#                     GDAL window and passes it through.
# - "compute":        fn(inputs) with `inputs` a list of chunk arrays in
#                     `input_nodes` order, each padded to the stage halo;
#                     returns the chunk-core array.
# - "reduce_partial": fn(inputs) -> named list of per-chunk partials.
# - "reduce_combine": fn(partials) with `partials` a list over chunks of
#                     the partial lists; returns the final array/scalar.
# - "warp":           executed by GDAL (Phase 4b); fn is identity.
#
# Halo contract (D14, generalised by D22): stage inputs arrive padded to
# exactly `halo + out_pad` cells per side; cells outside the raster are
# NaN (nodata semantics). Each focal member consumes `radius` cells of
# padding via shifted slices, so each export carries its `export_pads`
# entry (0 when the stage has no downstream halo consumers).
# ---------------------------------------------------------------------------

#' One schedulable unit of a Plan.
#'
#' @param id Stage id (dense, 1-based).
#' @param kind One of "source_read", "compute", "reduce_partial",
#'   "reduce_combine", "warp".
#' @param members IR node ids composed into this stage (ascending = topo).
#' @param fn The composed stage closure (see calling conventions).
#' @param halo Halo radius in pixels the stage requires on its inputs.
#' @param grid Output `GridSpec` of the stage.
#' @param chunks `ChunkGrid` partitioning the stage's output.
#' @param device Device tag ("cpu" until Phase 7).
#' @param inputs Stage ids feeding this stage.
#' @param input_nodes IR node ids whose values `fn` receives, in order.
#' @param exports Member node ids `fn` returns, ascending (consumed by
#'   other stages, plus the stage tail).
#' @param out_pad Spatial padding the stage's chunks are computed with
#'   (D22): consumers needing a halo on this stage's exports receive it
#'   as a recomputed ring instead of a materialise-first refusal.
#'   Inputs arrive padded to `halo + out_pad`.
#' @param export_pads Integer vector parallel to `exports`: the padding
#'   each export value carries (post-focal exports carry less than
#'   pre-focal ones). Empty means all zero.
#' @return A `Stage`.
#' @export
Stage <- S7::new_class(
  "Stage",
  properties = list(
    id          = S7::class_integer,
    kind        = S7::class_character,
    members     = S7::class_integer,
    fn          = S7::class_function,
    halo        = S7::class_integer,
    grid        = GridSpec,
    chunks      = ChunkGrid,
    device      = S7::class_character,
    inputs      = S7::class_integer,
    input_nodes = S7::class_integer,
    exports     = S7::class_integer,
    out_pad     = S7::new_property(S7::class_integer, default = 0L),
    export_pads = S7::new_property(S7::class_integer,
                                   default = quote(integer(0)))
  ),
  validator = function(self) {
    kinds <- c("source_read", "compute", "reduce_partial",
               "reduce_combine", "warp")
    if (length(self@kind) != 1L || !self@kind %in% kinds)
      return(paste0("`kind` must be one of: ", paste(kinds, collapse = ", ")))
    if (length(self@halo) != 1L || self@halo < 0L)
      return("`halo` must be a single non-negative integer")
    NULL
  }
)

#' A physical execution plan: stages in dependency order.
#'
#' @param stages List of `Stage`, indexed by stage id.
#' @param sink Id of the terminal stage.
#' @param graph The IR `Graph` the plan was built from.
#' @return A `Plan`.
#' @export
Plan <- S7::new_class(
  "Plan",
  properties = list(
    stages = S7::class_list,
    sink   = S7::class_integer,
    # Multi-export (design/multi-export-collect.md): named NODE ids, one
    # per requested sink. Length <= 1 means the classic single-sink plan.
    sinks  = S7::new_property(S7::class_integer, default = quote(integer(0))),
    graph  = Graph
  )
)

S7::method(print, Plan) <- function(x, ...) {
  cat("<Plan>", length(x@stages), "stages, sink =", x@sink, "\n")
  for (s in x@stages) {
    cat(sprintf(
      "  [%d] %-14s members=(%s) halo=%d%s chunks=%dx%d inputs=(%s)\n",
      s@id, s@kind, paste(s@members, collapse = ","), s@halo,
      if (s@out_pad > 0L) sprintf(" pad=%d", s@out_pad) else "",
      s@chunks@chunk_dim[1L], s@chunks@chunk_dim[2L],
      paste(s@inputs, collapse = ",")))
  }
  invisible(x)
}
