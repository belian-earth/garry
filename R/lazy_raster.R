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

# Friendly type guard for public entry points.
.assert_class <- function(x, cls, name, arg = rlang::caller_arg(x),
                          call = rlang::caller_env()) {
  if (!S7::S7_inherits(x, cls))
    cli::cli_abort("{.arg {arg}} must be a {.cls {name}}.", call = call)
}

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
#' @param resampling GDAL resampling used when a read reprojects or rescales
#'   this source onto the analysis grid. `"near"` (default) preserves exact
#'   source values; use `"bilinear"`, `"average"`, `"cubic"`, ... to interpolate.
#' @return A `LazyRaster`.
#' @export
lazy_source <- function(path, band = 1L, graph = graph_new(), nodata = NULL,
                        open_options = character(0), grid = NULL,
                        block_dim = NULL, resampling = "near") {
  if (is.null(grid)) {
    meta <- gdal_grid_spec(path, band = as.integer(band),
                           open_options = open_options)
    grid <- meta$grid
    nodata <- if (is.null(nodata)) meta$nodata else as.numeric(nodata)
    block_dim <- meta$block_dim
  } else {
    .assert_class(grid, GridSpec, "GridSpec")
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
    open_options = open_options,
    resampling   = as.character(resampling)
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
#' Over a `LazyDataset`, `fn` is applied to every value band (a single dataset
#' input only); `bands` restricts which bands, and non-selected bands pass
#' through unchanged.
#'
#' @param ... `LazyRaster` inputs (at least one), or a single `LazyDataset`.
#' @param fn Function of as many arrays as there are inputs.
#' @param dtype Optional output dtype override.
#' @param bands `LazyDataset` only: bands to map over (default: all value bands).
#' @return A `LazyRaster`, or a `LazyDataset` when given one.
#' @export
lazy_map <- function(..., fn, dtype = NULL, bands = NULL) {
  xs <- list(...)
  stopifnot(length(xs) >= 1L, is.function(fn))
  if (S7::S7_inherits(xs[[1L]], LazyDataset)) return(.ds_map(xs, fn, dtype, bands))
  graph <- xs[[1L]]@graph
  ids <- vapply(seq_along(xs), function(i) {
    x <- xs[[i]]
    if (!S7::S7_inherits(x, LazyRaster))
      cli::cli_abort("input {i} must be a {.cls LazyRaster}")
    if (!grid_equal(xs[[1L]]@grid, x@grid))
      cli::cli_abort("input {i} is not on the same grid; {.fn align} it first")
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
  along <- rlang::arg_match(along, c("t", "band"))
  graph <- xs[[1L]]@graph
  ids <- vapply(seq_along(xs), function(i) {
    x <- xs[[i]]
    if (!S7::S7_inherits(x, LazyRaster))
      cli::cli_abort("layer {i} must be a {.cls LazyRaster}")
    if (!grid_equal(xs[[1L]]@grid, x@grid))
      cli::cli_abort("layer {i} is not on the same grid; {.fn align} it first")
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
    cli::cli_abort("grids differ; use {.code align(a, b, to = ...)} first")
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
#' Over a `LazyDataset`, the stencil is applied to every value band per slice;
#' `bands` restricts which bands.
#'
#' @param x        LazyRaster, or a `LazyDataset`.
#' @param fn       Function over the list of shifted arrays (see above).
#' @param radius   Halo in pixels (mandatory: the footprint cannot be
#'                 inferred from `fn`; decision D14).
#' @param boundary Boundary policy; only "nodata" in v1.
#' @param bands    `LazyDataset` only: bands to apply to (default: all value
#'                 bands).
#'
#' @export
focal <- function(x, fn, radius, boundary = "nodata", bands = NULL) {
  if (S7::S7_inherits(x, LazyDataset))
    return(.ds_focal(x, fn, radius, rlang::arg_match(boundary, "nodata"), bands))
  .assert_class(x, LazyRaster, "LazyRaster")
  boundary <- rlang::arg_match(boundary, "nodata")
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
#' Over a `LazyDataset`, each band is reduced independently (over `"t"`: stack
#' the band's slices and collapse time to a composite); `bands` restricts which
#' bands. `over = "band"` collapses the band axis, returning a `LazyRaster`.
#'
#' @param x A `LazyRaster`, or a `LazyDataset`.
#' @param op Reduction name, e.g. `"mean"`, or a custom anvl reducer `fn(x, dims)`.
#' @param over Names of dims to reduce over (subset of `names(dims)`).
#' @param nan_rm Skip NaN (nodata) values?
#' @param bands `LazyDataset` only: bands to reduce (default: all bands).
#' @return A `LazyRaster` on the reduced grid, or a `LazyDataset` when given one.
#' @export
reduce_over <- function(x, op, over, nan_rm = TRUE, bands = NULL) {
  if (S7::S7_inherits(x, LazyDatasetGroups))
    return(.dsg_reduce(x, op, over, isTRUE(nan_rm), bands))
  if (S7::S7_inherits(x, LazyDataset))
    return(.ds_reduce(x, op, over, isTRUE(nan_rm), bands))
  .assert_class(x, LazyRaster, "LazyRaster")
  # A custom reducer arrives as a function: an anvl kernel `fn(x, dims)`
  # collapsing `dims` (e.g. per-pixel OLS/harmonic fit over time). Carried on
  # the node as `fn`; `op` becomes the sentinel "custom" (dtype = parent's).
  fn <- list()
  if (is.function(op)) {
    fn <- list(op)
    op <- "custom"
  }
  grid <- .reduce_grid(x@grid, op, over)   # validates `over`, applies D7
  id <- graph_add(
    x@graph,
    ReduceNode,
    parents = x@node_id,
    grid    = grid,
    op      = op,
    over    = over,
    nan_rm  = isTRUE(nan_rm),
    fn      = fn
  )
  LazyRaster(graph = x@graph, node_id = id, grid = grid)
}

#' A band reducer for a linear combination of bands.
#'
#' Returns an anvl reducer `fn(x, dims)` for `reduce_over(cube, fn, over =
#' "band")`: it centres each band (optional) and forms the weighted sum
#' `sum_b weights[b] * (band_b - center[b])` per pixel -- a linear projection of
#' the band vector. This is the "reduce over bands" primitive behind spectral
#' indices, linear/logistic prediction, and PCA. For multiple outputs (e.g. the
#' first `k` principal components) build one reducer per weight column and stack:
#'
#' ```r
#' pc <- lapply(1:3, \(i) reduce_over(cube, band_project(rot[, i], centre),
#'                                    over = "band"))
#' collect(lazy_stack(pc, along = "band"))            # (3, y, x)
#' ```
#'
#' @param weights Per-band coefficients (length = number of bands).
#' @param center Optional per-band centre subtracted before weighting (e.g. a
#'   PCA's column means); length must match `weights`.
#' @return A function `fn(x, dims)` suitable for [reduce_over()] `over = "band"`.
#' @export
band_project <- function(weights, center = NULL) {
  w <- as.numeric(weights)
  ctr <- if (is.null(center)) NULL else as.numeric(center)
  if (!is.null(ctr) && length(ctr) != length(w))
    cli::cli_abort("{.arg center} must be the same length as {.arg weights}.")
  force(w); force(ctr)
  function(x, dims) {
    rank <- if (.g_traced(x)) length(.g_shape(x)) else length(dim(x))
    lead <- function(v) {                       # v -> (length(v), 1, ..., 1)
      a <- array(as.numeric(v), c(length(v), rep(1L, rank - 1L)))
      if (.g_traced(x)) g_upload(a, "f32") else a
    }
    xc <- if (is.null(ctr)) x else {
      b <- g_broadcast_arrays(x, lead(ctr)); b[[1L]] - b[[2L]]
    }
    b <- g_broadcast_arrays(xc, lead(w))
    g_sum(b[[1L]] * b[[2L]], dims)
  }
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
  .assert_class(x, LazyRaster, "LazyRaster")
  boundary <- rlang::arg_match(boundary, "nodata")
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
    fn       = function(sh) cli::cli_abort("kernel focal is evaluated from weights", .internal = TRUE),
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
#' Paste fast path: when `x` is already exactly on the target grid
#' (same CRS, transform, extent and dims; `grid_equal()`), `align()`
#' is a no-op returning `x` — reads stay plain windowed reads, with no
#' warp barrier splitting the plan. This is the single-CRS-zone
#' workflow: pin the analysis grid to the sources' native grid and
#' nothing warps. Unlike odc-stac's `ttol`, only EXACT equality
#' pastes: a sub-pixel-shifted paste silently moves every pixel up to
#' half a cell, so near-misses warp.
#'
#' @param x A `LazyRaster`.
#' @param to Target grid: a `GridSpec` or another `LazyRaster`.
#' @param resampling GDAL resampling method.
#' @return A `LazyRaster` on the target grid.
#' @export
align <- function(x, to, resampling = "bilinear") {
  .assert_class(x, LazyRaster, "LazyRaster")
  target <- if (S7::S7_inherits(to, LazyRaster)) to@grid else to
  .assert_class(target, GridSpec, "GridSpec", arg = "to")
  target <- .grid_retype(target, x@grid@dtype)
  if (grid_equal(x@grid, target)) return(x)
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

# print() cards and draw() live in draw.R.
