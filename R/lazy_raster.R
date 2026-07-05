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
#' @param nodata Optional nodata sentinel. An integer source with a
#'   declared nodata is promoted to f32 (NaN carries nodata, decision D8).
#' @return A `LazyRaster`.
#' @export
lazy_source <- function(path, band = 1L, graph = graph_new(), nodata = NULL) {
  grid <- .read_grid_stub(path)
  nodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
  if (length(nodata) == 1L && .dtype_family(grid@dtype) != "float")
    grid <- .grid_retype(grid, "f32")
  id <- graph_add(
    graph,
    SourceNode,
    parents = integer(0),
    grid    = grid,
    path    = path,
    band    = as.integer(band),
    nodata  = nodata
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

# Binary op helper. Grid mismatch errors (align stays explicit, decision
# D8's cousin); graph mismatch auto-merges by importing b's subgraph into
# a's graph (decision D6) — users never manage graphs by hand.
.lazy_binop <- function(a, b, op, divide = FALSE) {
  if (!grid_equal(a@grid, b@grid))
    stop("grids differ; use align(a, b, to = ...) first")
  graph <- a@graph
  b_id <- if (identical(graph@nodes, b@graph@nodes)) b@node_id
          else graph_import(graph, b@graph, b@node_id)
  grid <- .grid_retype(
    a@grid, dtype_promote(a@grid@dtype, b@grid@dtype, divide = divide))
  id <- graph_add(
    graph,
    MapNode,
    parents = c(a@node_id, b_id),
    grid    = grid,
    fn      = op
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

# Scalar op helper: scalar on one side. Scalars are weakly typed: they
# never widen the raster dtype; only division forces a float result.
.lazy_scalar_op <- function(lr, s, op, scalar_first, divide = FALSE) {
  fn <- if (scalar_first) function(x) op(s, x) else function(x) op(x, s)
  grid <- .grid_retype(
    lr@grid, dtype_promote(lr@grid@dtype, lr@grid@dtype, divide = divide))
  id <- graph_add(
    lr@graph,
    MapNode,
    parents = lr@node_id,
    grid    = grid,
    fn      = fn
  )
  LazyRaster(graph = lr@graph, node_id = id, grid = grid)
}

# S7 registers methods on the base arithmetic generics via double dispatch.
# We register + - * / for (LazyRaster, LazyRaster) and the scalar mixes.
for (op_name in c("+", "-", "*", "/")) {
  op_fn <- get(op_name, envir = baseenv())
  is_div <- op_name == "/"
  S7::method(op_fn, list(LazyRaster, LazyRaster)) <-
    local({
      f <- op_fn; d <- is_div
      function(e1, e2) .lazy_binop(e1, e2, f, divide = d)
    })
  S7::method(op_fn, list(LazyRaster, S7::class_numeric)) <-
    local({
      f <- op_fn; d <- is_div
      function(e1, e2) .lazy_scalar_op(e1, e2, f, FALSE, divide = d)
    })
  S7::method(op_fn, list(S7::class_numeric, LazyRaster)) <-
    local({
      f <- op_fn; d <- is_div
      function(e1, e2) .lazy_scalar_op(e2, e1, f, TRUE, divide = d)
    })
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
#' `op` is a reduction name (see `.reduce_ops`), not a function: the
#' planner needs op identity for algebraic decomposition (D12) and dtype
#' rules. `nan_rm = TRUE` (the default) skips nodata, matching R's
#' `na.rm = TRUE` under the NaN-sentinel model (D8).
#'
#' @param x A `LazyRaster`.
#' @param op Reduction name, e.g. `"mean"`.
#' @param over Names of dims to reduce over (subset of `names(dims)`).
#' @param nan_rm Skip NaN (nodata) values?
#' @return A `LazyRaster` on the reduced grid.
#' @export
reduce_over <- function(x, op, over, nan_rm = TRUE) {
  stopifnot(S7::S7_inherits(x, LazyRaster))
  grid <- .reduce_grid(x@grid, op, over)   # validates `over`, applies D7
  id <- graph_add(
    x@graph,
    ReduceNode,
    parents = x@node_id,
    grid    = grid,
    op      = op,
    over    = over,
    nan_rm  = isTRUE(nan_rm)
  )
  LazyRaster(graph = x@graph, node_id = id, grid = grid)
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
