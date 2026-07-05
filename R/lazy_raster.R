#' @include graph.R node.R grid.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# LazyRaster: user-facing array-like over the IR graph.
#
# Thin wrapper around (graph, node_id, grid). Operators add nodes and
# return new LazyRasters sharing the graph. Users never see the IR.
# ---------------------------------------------------------------------------

#' Lazy raster array.
#'
#' @param graph The shared IR `Graph`.
#' @param node_id Integer id of this raster's node.
#' @param grid Cached `GridSpec` for fast dim/crs access.
#' @return A `LazyRaster`.
#' @export
LazyRaster <- S7::new_class(
  "LazyRaster",
  properties = list(
    graph   = Graph,
    node_id = S7::class_integer,
    grid    = GridSpec
  )
)

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

#' Build a LazyRaster from a GDAL source.
#'
#' Stubbed grid inspection for the Phase 1/2 sketch: a real implementation
#' reads CRS/transform/extent/dims via gdalraster. `graph` defaults to a
#' fresh graph; pass an existing one to share.
#'
#' @param path Path or VSI URL readable by GDAL.
#' @param band 1-based band index.
#' @param graph `Graph` to add the source to; defaults to a fresh graph.
#' @return A `LazyRaster`.
#' @export
lazy_source <- function(path, band = 1L, graph = graph_new()) {
  grid <- .read_grid_stub(path)
  id <- graph_add(
    graph,
    SourceNode,
    parents = integer(0),
    grid    = grid,
    path    = path,
    band    = as.integer(band)
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

# Placeholder for the Phase 4 gdalraster adapter. Returns a default grid
# so Phase 2 code paths are exercisable end-to-end on stubs.
.read_grid_stub <- function(path) {
  GridSpec(
    crs       = "EPSG:4326",
    transform = c(0, 1, 0, 0, 0, -1),
    extent    = c(0, -100, 100, 0),
    dims       = c(100L, 100L),
    dtype     = "f32"
  )
}

# ---------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------

# Binary op helper: requires grid equality and a shared graph.
.lazy_binop <- function(a, b, op) {
  if (!grid_equal(a@grid, b@grid))
    stop("grids differ; use align(a, b, to = ...) first")
  if (!identical(a@graph, b@graph))
    stop("operands belong to different graphs")
  id <- graph_add(
    a@graph,
    MapNode,
    parents = c(a@node_id, b@node_id),
    grid    = a@grid,
    fn      = op
  )
  LazyRaster(graph = a@graph, node_id = id, grid = a@grid)
}

# Scalar op helper: scalar on one side.
.lazy_scalar_op <- function(lr, s, op, scalar_first) {
  fn <- if (scalar_first) function(x) op(s, x) else function(x) op(x, s)
  id <- graph_add(
    lr@graph,
    MapNode,
    parents = lr@node_id,
    grid    = lr@grid,
    fn      = fn
  )
  LazyRaster(graph = lr@graph, node_id = id, grid = lr@grid)
}

# S7 registers methods on the base arithmetic generics via double dispatch.
# We register + - * / for (LazyRaster, LazyRaster) and the scalar mixes.
for (op_name in c("+", "-", "*", "/")) {
  op_fn <- get(op_name, envir = baseenv())
  S7::method(op_fn, list(LazyRaster, LazyRaster)) <-
    local({ f <- op_fn; function(e1, e2) .lazy_binop(e1, e2, f) })
  S7::method(op_fn, list(LazyRaster, S7::class_numeric)) <-
    local({ f <- op_fn; function(e1, e2) .lazy_scalar_op(e1, e2, f, FALSE) })
  S7::method(op_fn, list(S7::class_numeric, LazyRaster)) <-
    local({ f <- op_fn; function(e1, e2) .lazy_scalar_op(e2, e1, f, TRUE) })
}

# ---------------------------------------------------------------------------
# Methods
# ---------------------------------------------------------------------------

#' Focal (stencil) op.
#'
#' @param x        LazyRaster.
#' @param fn       R function taking a (2h+1) x (2h+1) neighbourhood (or a
#'                 whole padded chunk, depending on the kernel convention
#'                 settled in Phase 5) and returning the centre value.
#' @param radius   Halo in pixels.
#' @param boundary One of "constant", "reflect", "nearest", "wrap", "none".
#'
#' @export
focal <- function(x, fn, radius, boundary = "reflect") {
  stopifnot(S7::S7_inherits(x, LazyRaster))
  id <- graph_add(
    x@graph,
    FocalNode,
    parents  = x@node_id,
    grid     = x@grid,
    fn       = fn,
    radius   = as.integer(radius),
    boundary = boundary
  )
  LazyRaster(graph = x@graph, node_id = id, grid = x@grid)
}

#' Reduction over named dims.
#'
#' @param x A `LazyRaster`.
#' @param fn Reducing function.
#' @param over Names of dims to reduce over.
#' @return A `LazyRaster`.
#' @export
reduce_over <- function(x, fn, over) {
  stopifnot(S7::S7_inherits(x, LazyRaster))
  id <- graph_add(
    x@graph,
    ReduceNode,
    parents = x@node_id,
    grid    = x@grid,         # TODO: drop reduced dims in output_grid method
    fn      = fn,
    over    = over
  )
  LazyRaster(graph = x@graph, node_id = id, grid = x@grid)
}

# `print` via S7
S7::method(print, LazyRaster) <- function(x, ...) {
  cat("<LazyRaster>\n")
  cat("  node_id:", x@node_id, "\n")
  cat("  crs:    ", x@grid@crs, "\n")
  cat("  dim:    ", paste(x@grid@dims, collapse = " x "), "\n")
  cat("  dtype:  ", x@grid@dtype, "\n")
  cat("  nodes:  ", length(graph_ids(x@graph)), "in graph\n")
  invisible(x)
}
