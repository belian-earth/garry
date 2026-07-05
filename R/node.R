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

#' A GDAL-readable source: path + band.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param path Path or VSI URL readable by GDAL.
#' @param band 1-based band index.
#' @return A `SourceNode`.
#' @export
SourceNode <- S7::new_class(
  "SourceNode",
  parent = Node,
  properties = list(
    path = S7::class_character,
    band = S7::class_integer
  )
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
#' @param fn Neighbourhood function.
#' @param radius Halo radius in pixels.
#' @param boundary Boundary policy.
#' @return A `FocalNode`.
#' @export
FocalNode <- S7::new_class(
  "FocalNode",
  parent = Node,
  properties = list(
    fn       = S7::class_function,
    radius   = S7::class_integer,
    boundary = S7::class_character
  )
)

#' Reduction over named dims. Barrier: forces materialisation of its inputs.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param fn Reducing function.
#' @param over Names of dims to reduce over.
#' @return A `ReduceNode`.
#' @export
ReduceNode <- S7::new_class(
  "ReduceNode",
  parent = Node,
  properties = list(
    fn   = S7::class_function,
    over = S7::class_character
  )
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
