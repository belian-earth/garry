# ---------------------------------------------------------------------------
# IR node hierarchy.
#
# Each op is an S7 class inheriting from the abstract Node. Nodes are
# immutable values; rewrites produce new nodes. All graph state lives in
# the containing Graph's environment.
# ---------------------------------------------------------------------------

#' Abstract IR node.
#'
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
#' composed with neighbouring fusable nodes and wrapped in `anvil::jit()`
#' at plan time.
#'
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
#' @export
StackNode <- S7::new_class(
  "StackNode",
  parent = Node,
  properties = list(
    along = S7::class_character
  )
)

#' Output of the composition pass. Holds a composed R function assembled
#' from its members; ready for `anvil::jit()` at execution time.
#'
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
