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
#' @param resampling GDAL resampling used when a read reprojects/rescales the
#'   source onto the analysis grid (default "near").
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
    open_options = S7::class_character,
    # GDAL resampling used when the read reprojects/rescales onto the analysis
    # grid ("near" preserves exact values; the default, and forced for QA masks).
    resampling   = S7::new_property(S7::class_character, default = "near")
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
#' `op` is normally a name from `.reduce_ops`: the planner needs op
#' identity to decide algebraic decomposition (D12) and output dtype, and
#' the executor maps it to the ops vocabulary. A CUSTOM reducer may
#' instead be supplied as `fn` (a length-1 list holding an anvl function
#' `fn(x, dims)` that collapses `dims`), with `op = "custom"`; the
#' executor calls it directly. A custom reducer cannot be decomposed
#' across spatial chunks, so it is supported over the `t`/`band` axes
#' (each spatial chunk holds the full axis), not over `x`/`y`.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes (may be empty).
#' @param grid Output `GridSpec` of this node.
#' @param op Reduction name, e.g. "mean" (see `.reduce_ops`), or "custom".
#' @param over Names of dims to reduce over.
#' @param nan_rm Skip NaN (nodata) values? (Named ops only; a custom `fn`
#'   handles NaN itself.)
#' @param fn Length-0 (named op) or length-1 list holding a custom anvl
#'   reducer `fn(x, dims)`.
#' @return A `ReduceNode`.
#' @export
ReduceNode <- S7::new_class(
  "ReduceNode",
  parent = Node,
  properties = list(
    op     = S7::class_character,
    over   = S7::class_character,
    nan_rm = S7::class_logical,
    fn     = S7::class_list
  ),
  validator = function(self) {
    custom <- length(self@fn) > 0L
    if (custom && (length(self@fn) != 1L || !is.function(self@fn[[1L]])))
      return("`fn` must be a length-1 list holding a reducer function")
    if (!custom && (length(self@op) != 1L || !self@op %in% .reduce_ops))
      return(paste0("`op` must be one of: ", paste(.reduce_ops, collapse = ", ")))
    if (length(self@over) < 1L)
      return("`over` must name at least one dim")
    NULL
  }
)

#' Scan along a named dim, preserving it. Barrier over `over`.
#'
#' The missing IR shape between `MapNode` and `ReduceNode`: carry state
#' sequentially along one non-spatial axis while emitting a same-length
#' series (Kalman smoothers, EWMA, IIR filters, cumulative ops). The
#' output grid is the parent grid unchanged (the scanned axis survives),
#' optionally with a dtype override.
#'
#' The body kernel is `fn(xs, margin) -> y`: `xs` is the LIST of parent
#' chunk values (length >= 1; multi-parent scans read several cubes in
#' lockstep), `margin` is the scanned axis position from `.dim_margins`,
#' and `y` has the same shape as `xs[[1]]`. Inside, the body uses
#' `g_scan()` to carry state along `margin`; everything else in the
#' chunk (the spatial axes) is batched through the carry. Like a custom
#' reducer, a scan cannot be decomposed across spatial chunks, so it is
#' supported over `t`/`band` only (each spatial chunk holds the full
#' axis).
#'
#' `direction` is declarative metadata (drawn, hashed into the kernel
#' signature): `"bidir"` bodies run a forward and a reverse `g_scan()`
#' internally as ONE fused kernel, so forward state never crosses a node
#' boundary.
#'
#' @param id Integer node id (assigned by `graph_add()`).
#' @param parents Integer ids of parent nodes.
#' @param grid Output `GridSpec` of this node.
#' @param over Single dim name to scan along (`"t"` or `"band"`).
#' @param direction One of `"forward"`, `"backward"`, `"bidir"`.
#' @param fn Length-1 list holding the scan body `fn(xs, margin)`.
#' @param dtype Length-0 (parent's dtype) or length-1 dtype override.
#' @return A `ScanNode`.
#' @export
ScanNode <- S7::new_class(
  "ScanNode",
  parent = Node,
  properties = list(
    over      = S7::class_character,
    direction = S7::class_character,
    fn        = S7::class_list,
    dtype     = S7::class_character
  ),
  validator = function(self) {
    if (length(self@over) != 1L)
      return("`over` must name exactly one dim")
    if (self@over %in% c("x", "y"))
      return("scanning over a spatial dim is not supported (chunks tile x/y)")
    if (length(self@direction) != 1L ||
        !self@direction %in% c("forward", "backward", "bidir"))
      return("`direction` must be one of: forward, backward, bidir")
    if (length(self@fn) != 1L || !is.function(self@fn[[1L]]))
      return("`fn` must be a length-1 list holding the scan body function")
    if (length(self@dtype) > 1L ||
        (length(self@dtype) == 1L && !dtype_valid(self@dtype)))
      return(paste0("`dtype` must be empty or one of: ",
                    paste(.garry_dtypes, collapse = ", ")))
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
