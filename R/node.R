#' @include grid.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# IR node hierarchy.
#
# Each op is an S7 class inheriting from the abstract Node. Nodes are
# immutable values; rewrites produce new nodes. All graph state lives in
# the containing Graph's environment.
# ---------------------------------------------------------------------------

# Reduction vocabulary. Named ops (not arbitrary functions) so the
# planner can decide algebraic decomposition (D12) and output dtype.
.reduce_ops <- c("sum", "mean", "min", "max", "prod",
                 "median", "quantile", "sd", "var",
                 "count", "any", "all")

#' Abstract IR node.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @return A `Node` subclass instance.
#' @export
Node <- S7::new_class(
  "Node",
  abstract = TRUE,
  properties = list(
    id      = S7::class_integer,
    parents = S7::class_integer,   # parent ids (may be empty)
    grid    = GridSpec
  )
)

#' A GDAL-readable source: path + band + optional nodata sentinel.
#'
#' A declared `nodata` on an integer source promotes the source's output
#' dtype to f32 so NaN can carry nodata downstream (decision D8); the
#' executor rewrites `value == nodata` to NaN at read time.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param path Path or VSI URL readable by GDAL.
#' @param band 1-based band index.
#' @param nodata Length-0 (absent) or length-1 nodata sentinel value.
#' @param block_dim Native GDAL block size (length 2), or length 0 if
#'   unknown; the chunking pass snaps chunk sizes to it.
#' @param open_options GDAL open options ("KEY=VALUE"), e.g. GTI FILTER.
#' @return A `SourceNode`.
#' @export
SourceNode <- S7::new_class(
  "SourceNode",
  parent = Node,
  properties = list(
    path         = S7::class_character,
    band         = S7::class_integer,
    nodata       = S7::class_numeric,
    block_dim    = S7::class_integer,
    open_options = S7::class_character
  ),
  validator = function(self) {
    if (length(self@nodata) > 1L)
      return("`nodata` must be length 0 (absent) or 1")
    NULL
  }
)

#' Elementwise map. `fn` is an R function over scalars/arrays; it will be
#' composed with neighbouring fusable nodes and wrapped in `anvl::jit()`
#' at plan time.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param fn Elementwise R function.
#' @return A `MapNode`.
#' @export
MapNode <- S7::new_class(
  "MapNode",
  parent = Node,
  properties = list(
    fn = S7::class_function
  )
)

#' Focal (stencil) op. `radius` is the halo in pixels; `boundary` is one
#' of "constant", "reflect", "nearest", "wrap", "none".
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param fn Neighbourhood function (over the list of shifted arrays).
#' @param radius Halo radius in pixels.
#' @param boundary Boundary policy.
#' @param weights Optional linear kernel, flattened row-major over
#'   (dy, dx), length (2*radius+1)^2. When present the op is the
#'   weighted sum and is differentiable wrt the weights (Phase 6).
#' @return A `FocalNode`.
#' @export
FocalNode <- S7::new_class(
  "FocalNode",
  parent = Node,
  properties = list(
    fn       = S7::class_function,
    radius   = S7::class_integer,
    boundary = S7::class_character,
    weights  = S7::class_numeric
  ),
  validator = function(self) {
    k <- (2L * self@radius + 1L)^2
    if (length(self@weights) > 0L && length(self@weights) != k)
      return(sprintf("`weights` must have length %d for radius %d", k,
                     self@radius))
    NULL
  }
)

#' Reduction over named dims. Barrier: forces materialisation of its inputs.
#'
#' `op` is a name from `.reduce_ops`, not an arbitrary function: the
#' planner needs op identity to decide algebraic decomposition (D12) and
#' output dtype, and the executor maps it to the ops vocabulary.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param op Reduction name, e.g. "mean" (see `.reduce_ops`).
#' @param over Names of dims to reduce over.
#' @param nan_rm Skip NaN (nodata) values?
#' @return A `ReduceNode`.
#' @export
ReduceNode <- S7::new_class(
  "ReduceNode",
  parent = Node,
  properties = list(
    op     = S7::class_character,
    over   = S7::class_character,
    nan_rm = S7::class_logical
  ),
  validator = function(self) {
    if (length(self@op) != 1L || !self@op %in% .reduce_ops)
      return(paste0("`op` must be one of: ", paste(.reduce_ops, collapse = ", ")))
    if (length(self@over) < 1L)
      return("`over` must name at least one dim")
    NULL
  }
)

#' Lazy resample/reproject to a target grid. Output of `align()`. Barrier.
#' At execution time this materialises as a gdalraster VRT warp.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param target_grid `GridSpec` to warp onto.
#' @param resampling Resampling method ("nearest", "bilinear", "cubic", ...).
#' @return A `WarpNode`.
#' @export
WarpNode <- S7::new_class(
  "WarpNode",
  parent = Node,
  properties = list(
    target_grid = GridSpec,
    resampling  = S7::class_character  # "nearest", "bilinear", "cubic", ...
  )
)

#' Combine inputs along a named dim (e.g. time).
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param along Name of the dim to stack along.
#' @return A `StackNode`.
#' @export
StackNode <- S7::new_class(
  "StackNode",
  parent = Node,
  properties = list(
    along = S7::class_character
  )
)

#' Output of the composition pass. Holds a composed R function assembled
#' from its members; ready for `anvl::jit()` at execution time.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param fn Composed stage function.
#' @param members Ids of the absorbed nodes.
#' @param halo Combined halo radius of the members.
#' @return A `FusedNode`.
#' @export
FusedNode <- S7::new_class(
  "FusedNode",
  parent = Node,
  properties = list(
    fn      = S7::class_function,
    members = S7::class_integer,     # ids of absorbed nodes
    halo    = S7::class_integer
  )
)
