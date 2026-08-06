#' @include node.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# S7 generics for planner passes. Each op answers for itself; adding a new
# op class only requires registering methods here (or co-located with the
# op definition). No central switchboard.
# ---------------------------------------------------------------------------

#' Halo radius required by this node from its inputs.
#'
#' @param node An IR `Node`.
#' @param ... Passed to methods.
#' @return Integer halo radius in pixels.
#' @export
required_halo <- S7::new_generic("required_halo", "node")
S7::method(required_halo, SourceNode) <- function(node) 0L
S7::method(required_halo, MapNode)    <- function(node) 0L
S7::method(required_halo, FocalNode)  <- function(node) node@radius
S7::method(required_halo, ReduceNode) <- function(node) 0L
S7::method(required_halo, ScanNode)   <- function(node) 0L
S7::method(required_halo, WarpNode)   <- function(node) 0L
S7::method(required_halo, StackNode)  <- function(node) 0L
S7::method(required_halo, FusedNode)  <- function(node) node@halo
S7::method(required_halo, PatchNode)  <- function(node) node@radius

#' Can this node be composed with fusable neighbours into a single kernel?
#'
#' @param node An IR `Node`.
#' @param ... Passed to methods.
#' @return `TRUE` or `FALSE`.
#' @export
fusable <- S7::new_generic("fusable", "node")
S7::method(fusable, MapNode)   <- function(node) TRUE
S7::method(fusable, FocalNode) <- function(node) TRUE
S7::method(fusable, StackNode) <- function(node) TRUE
S7::method(fusable, PatchNode) <- function(node) TRUE
S7::method(fusable, Node)      <- function(node) FALSE   # default: barrier

#' Does this node force a stage boundary?
#'
#' @param node An IR `Node`.
#' @param ... Passed to methods.
#' @return `TRUE` or `FALSE`.
#' @export
is_barrier <- S7::new_generic("is_barrier", "node")
S7::method(is_barrier, ReduceNode) <- function(node) TRUE
S7::method(is_barrier, ScanNode)   <- function(node) TRUE
S7::method(is_barrier, WarpNode)   <- function(node) TRUE
S7::method(is_barrier, Node)       <- function(node) FALSE

#' Compute the output grid given this node and its parents' grids.
#'
#' Default: first parent's grid (elementwise, focal, stack). Ops that
#' change the grid override (Warp, Reduce).
#'
#' @param node An IR `Node`.
#' @param ... Method arguments: `parent_grids`, a list of parent `GridSpec`s.
#' @return The node's output `GridSpec`.
#' @export
output_grid <- S7::new_generic("output_grid", "node")
S7::method(output_grid, SourceNode) <- function(node, parent_grids) node@grid
S7::method(output_grid, MapNode)    <- function(node, parent_grids) parent_grids[[1L]]
S7::method(output_grid, FocalNode)  <- function(node, parent_grids) parent_grids[[1L]]
S7::method(output_grid, StackNode)  <- function(node, parent_grids) {
  pg <- parent_grids[[1L]]
  if (node@along %in% names(pg@dims))
    .garry_error(paste0("cannot stack along existing dim `", node@along,
                        "`: the parents already carry it"),
                 "garry_plan_error")
  dtype <- Reduce(dtype_promote, vapply(parent_grids, function(p) p@dtype,
                                        character(1)))
  # The new axis leads the array (g_stack), and parent non-spatial dims
  # follow it, so dims order here mirrors .dim_layout(): stacking
  # (t, y, x) cubes along "band" yields a (band, t, y, x) cube whose
  # grid is (x, y, band, t). Parent labels (slice dates) carry through.
  extras <- pg@dims[setdiff(names(pg@dims), c("x", "y"))]
  dims <- c(pg@dims[c("x", "y")],
            stats::setNames(length(parent_grids), node@along),
            extras)
  GridSpec(crs = pg@crs, transform = pg@transform, extent = pg@extent,
           dims = dims, dtype = dtype, labels = pg@labels)
}
S7::method(output_grid, FusedNode)  <- function(node, parent_grids) parent_grids[[1L]]
S7::method(output_grid, WarpNode)   <- function(node, parent_grids) node@target_grid
S7::method(output_grid, ReduceNode) <- function(node, parent_grids) {
  .reduce_grid(parent_grids[[1L]], node@op, node@over)
}
S7::method(output_grid, ScanNode) <- function(node, parent_grids) {
  # Length-preserving: the scanned axis and its length survive. Only the
  # dtype may change (explicit override on the node).
  pg <- parent_grids[[1L]]
  if (!length(node@dtype)) pg else .grid_retype(pg, node@dtype)
}
S7::method(output_grid, PatchNode) <- function(node, parent_grids) {
  # Spatial geometry unchanged (the halo is consumed, not the core);
  # the band axis is consumed (out_bands == 0) or replaced by the
  # model's output channels.
  pg <- parent_grids[[1L]]
  dims <- pg@dims[setdiff(names(pg@dims), "band")]
  if (node@out_bands > 0L)
    dims <- c(dims, c(band = node@out_bands))
  labels <- pg@labels[setdiff(names(pg@labels), "band")]
  GridSpec(crs = pg@crs, transform = pg@transform, extent = pg@extent,
           dims = dims, labels = labels,
           dtype = if (length(node@dtype)) node@dtype else pg@dtype)
}

# Output dtype of a reduction (decision D7/D12): float-producing ops
# promote integers to f32; count is i32; any/all are pred; the algebraic
# extremes/sums keep their input dtype.
.reduce_dtype <- function(op, dtype) {
  if (op %in% c("mean", "median", "quantile", "sd", "var")) {
    if (.dtype_family(dtype) == "float") dtype else "f32"
  } else if (op == "count") {
    "i32"
  } else if (op %in% c("any", "all")) {
    "pred"
  } else {
    dtype
  }
}

# Grid algebra of a reduction (decision D7): reducing t/band drops the
# entry; reducing x/y collapses the axis to 1 with extent preserved and
# resolution rescaled to the full span.
.reduce_grid <- function(pg, op, over) {
  dims <- pg@dims
  unknown <- setdiff(over, names(dims))
  if (length(unknown) > 0L)
    cli::cli_abort("cannot reduce over missing dim(s): {unknown}")

  gt <- pg@transform
  if ("x" %in% over) {
    gt[2L] <- gt[2L] * dims[["x"]]
    dims[["x"]] <- 1L
  }
  if ("y" %in% over) {
    gt[6L] <- gt[6L] * dims[["y"]]
    dims[["y"]] <- 1L
  }
  drop_dims <- setdiff(intersect(over, c("t", "band")), character(0))
  dims <- dims[!names(dims) %in% drop_dims]

  GridSpec(crs = pg@crs, transform = gt, extent = pg@extent,
           dims = dims, dtype = .reduce_dtype(op, pg@dtype),
           labels = pg@labels[names(pg@labels) %in% names(dims)])
}
