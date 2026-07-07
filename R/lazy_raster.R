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
#' Grid, dtype, native block size, and file nodata come from GDAL via
#' the adapter (`gdal_grid_spec()`). A user-supplied `nodata` overrides
#' the file's. An integer source with nodata is promoted to f32 so NaN
#' can carry nodata downstream (decision D8); the sentinel-to-NaN
#' rewrite happens at read time in the adapter.
#'
#' Passing `grid` skips the GDAL open entirely: no metadata is read
#' until execution. Use it when the dataset's grid is known by
#' construction, e.g. GTI mosaics pinned to a target grid via
#' `gti_open_options()`, where opening every time slice just to
#' rediscover the grid costs a remote COG header fetch per slice
#' (measured: ~0.1 s each, serial, on the host). `grid` must describe
#' the dataset exactly as `path` + `open_options` open it, including
#' the source dtype; it is trusted, not checked. With `grid` given,
#' file nodata is NOT consulted (pass `nodata` explicitly if the
#' source has a sentinel).
#'
#' @param path Path or VSI URL readable by GDAL.
#' @param band 1-based band index.
#' @param graph `Graph` to add the source to; defaults to a fresh graph.
#' @param nodata Optional nodata sentinel overriding the file metadata.
#' @param open_options GDAL open options ("KEY=VALUE"), e.g. a GTI
#'   `FILTER` selecting one time slice of a tile index.
#' @param grid Optional `GridSpec` declaring the source's grid and
#'   dtype, skipping metadata discovery (see Details).
#' @param block_dim Optional native block size (x, y), only meaningful
#'   with `grid`; defaults to unconstrained.
#' @return A `LazyRaster`.
#' @export
lazy_source <- function(path, band = 1L, graph = graph_new(), nodata = NULL,
                        open_options = character(0), grid = NULL,
                        block_dim = NULL) {
  if (is.null(grid)) {
    meta <- gdal_grid_spec(path, band = as.integer(band),
                           open_options = open_options)
    grid <- meta$grid
    nodata <- if (is.null(nodata)) meta$nodata else as.numeric(nodata)
    block_dim <- meta$block_dim
  } else {
    stopifnot(S7::S7_inherits(grid, GridSpec))
    nodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
    block_dim <- if (is.null(block_dim)) integer(0) else as.integer(block_dim)
  }
  if (length(nodata) == 1L && .dtype_family(grid@dtype) != "float")
    grid <- .grid_retype(grid, "f32")
  id <- graph_add(
    graph,
    SourceNode,
    parents      = integer(0),
    grid         = grid,
    path         = path,
    band         = as.integer(band),
    nodata       = nodata,
    block_dim    = block_dim,
    open_options = open_options
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

#' Elementwise map over one or more aligned rasters.
#'
#' `fn` receives one traced array per input raster and returns one
#' array; it runs fused inside the surrounding XLA stage. Write it with
#' plain arithmetic and the `g_*` vocabulary (`g_ifelse`, `g_bitand`,
#' `g_cast`, ...). Inputs must share a grid (`align()` first otherwise);
#' graphs auto-merge (D6).
#'
#' The output dtype defaults to the promoted input dtype (D3); pass
#' `dtype` when `fn` changes the value domain, e.g. `"f32"` for a mask
#' that introduces NaN over an integer band.
#'
#' @param ... `LazyRaster` inputs (at least one).
#' @param fn Function of as many arrays as there are inputs.
#' @param dtype Optional output dtype override.
#' @return A `LazyRaster`.
#' @export
lazy_map <- function(..., fn, dtype = NULL) {
  xs <- list(...)
  stopifnot(length(xs) >= 1L, is.function(fn))
  graph <- xs[[1L]]@graph
  ids <- vapply(seq_along(xs), function(i) {
    x <- xs[[i]]
    stopifnot(S7::S7_inherits(x, LazyRaster))
    if (!grid_equal(xs[[1L]]@grid, x@grid))
      stop("input ", i, " is not on the same grid; align() it first")
    if (identical(graph@nodes, x@graph@nodes)) x@node_id
    else graph_import(graph, x@graph, x@node_id)
  }, integer(1))

  out_dtype <- dtype %||% Reduce(dtype_promote, vapply(
    seq_along(ids), function(i) graph_get(graph, ids[[i]])@grid@dtype,
    character(1)))
  grid <- .grid_retype(xs[[1L]]@grid, out_dtype)
  id <- graph_add(graph, MapNode, parents = ids, grid = grid, fn = fn)
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

#' Stack aligned rasters along a new outer dim (default time).
#'
#' All layers must share the spatial grid (align first otherwise);
#' dtypes promote to a common type. Chunks carry the stack as
#' (t, y, x) arrays (decision D17); temporal reductions
#' (`reduce_over(x, "median", "t")`) then run chunk-locally.
#'
#' @param xs List of `LazyRaster`s on one grid.
#' @param along Name of the new dim ("t" or "band").
#' @return A `LazyRaster` with an extra dim.
#' @export
lazy_stack <- function(xs, along = "t") {
  stopifnot(is.list(xs), length(xs) >= 1L)
  along <- match.arg(along, c("t", "band"))
  graph <- xs[[1L]]@graph
  ids <- vapply(seq_along(xs), function(i) {
    x <- xs[[i]]
    stopifnot(S7::S7_inherits(x, LazyRaster))
    if (!grid_equal(xs[[1L]]@grid, x@grid))
      stop("layer ", i, " is not on the same grid; align() it first")
    if (identical(graph@nodes, x@graph@nodes)) x@node_id
    else graph_import(graph, x@graph, x@node_id)
  }, integer(1))

  grids <- lapply(seq_along(ids), function(i) graph_get(graph, ids[[i]])@grid)
  node_tmp <- StackNode(id = 0L, parents = ids, grid = grids[[1L]],
                        along = along)
  grid <- output_grid(node_tmp, grids)
  id <- graph_add(
    graph,
    StackNode,
    parents = ids,
    grid    = grid,
    along   = along
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
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
#' `fn` receives a LIST of (2r+1)^2 shifted arrays, row-major over
#' (dy, dx) offsets, and returns one array: the whole neighbourhood is
#' processed vectorised across every pixel at once. This convention is
#' what lets the same closure run under the pure-R oracle and under
#' anvl's jit() (D10/D14). Example, a 3x3 sum:
#' `function(sh) Reduce("+", sh)`.
#'
#' Cells beyond the raster edge are NaN (nodata) — v1 supports only this
#' `boundary = "nodata"` policy; reflect/wrap arrive with Phase 9.
#'
#' @param x        LazyRaster.
#' @param fn       Function over the list of shifted arrays (see above).
#' @param radius   Halo in pixels (mandatory: the footprint cannot be
#'                 inferred from `fn`; decision D14).
#' @param boundary Boundary policy; only "nodata" in v1.
#'
#' @export
focal <- function(x, fn, radius, boundary = "nodata") {
  stopifnot(S7::S7_inherits(x, LazyRaster))
  boundary <- match.arg(boundary, "nodata")
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

#' Linear focal op with an explicit kernel (differentiable).
#'
#' The kernel is a (2r+1) x (2r+1) matrix of weights; the op is the
#' weighted sum over the window. Unlike `focal()` with an arbitrary
#' `fn`, a kernel focal is differentiable with respect to its weights:
#' pass the returned LazyRaster as `wrt` to `lazy_value_and_grad()`.
#'
#' @param x A `LazyRaster`.
#' @param weights Square odd-sided numeric matrix, rows = dy, cols = dx.
#' @param boundary Boundary policy; only "nodata" in v1.
#' @return A `LazyRaster`.
#' @export
focal_kernel <- function(x, weights, boundary = "nodata") {
  stopifnot(S7::S7_inherits(x, LazyRaster))
  boundary <- match.arg(boundary, "nodata")
  weights <- as.matrix(weights)
  stopifnot(nrow(weights) == ncol(weights), nrow(weights) %% 2L == 1L)
  radius <- (nrow(weights) - 1L) %/% 2L
  # Flatten row-major over (dy, dx) to match the shift enumeration.
  w <- as.numeric(t(weights))
  id <- graph_add(
    x@graph,
    FocalNode,
    parents  = x@node_id,
    grid     = x@grid,
    fn       = function(sh) stop("kernel focal is evaluated from weights"),
    radius   = radius,
    boundary = boundary,
    weights  = w
  )
  LazyRaster(graph = x@graph, node_id = id, grid = x@grid)
}

#' Lazily resample/reproject onto a target grid.
#'
#' Injects a WarpNode (a barrier, executed as a GDAL VRT warp in Phase
#' 4b). Alignment stays explicit: binary ops never auto-resample.
#'
#' @param x A `LazyRaster`.
#' @param to Target grid: a `GridSpec` or another `LazyRaster`.
#' @param resampling GDAL resampling method.
#' @return A `LazyRaster` on the target grid.
#' @export
align <- function(x, to, resampling = "bilinear") {
  stopifnot(S7::S7_inherits(x, LazyRaster))
  target <- if (S7::S7_inherits(to, LazyRaster)) to@grid else to
  stopifnot(S7::S7_inherits(target, GridSpec))
  target <- .grid_retype(target, x@grid@dtype)
  id <- graph_add(
    x@graph,
    WarpNode,
    parents     = x@node_id,
    grid        = target,
    target_grid = target,
    resampling  = resampling
  )
  LazyRaster(graph = x@graph, node_id = id, grid = target)
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
