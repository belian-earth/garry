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

# Grid accessors forward to the cached GridSpec (generics in grid.R).
S7::method(xmin, LazyRaster) <- function(x) xmin(x@grid)
S7::method(ymin, LazyRaster) <- function(x) ymin(x@grid)
S7::method(xmax, LazyRaster) <- function(x) xmax(x@grid)
S7::method(ymax, LazyRaster) <- function(x) ymax(x@grid)
S7::method(res, LazyRaster) <- function(x) res(x@grid)

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
  .outer_dims <- function(g) g@dims[!names(g@dims) %in% c("x", "y")]
  ids <- vapply(seq_along(xs), function(i) {
    x <- xs[[i]]
    if (!S7::S7_inherits(x, LazyRaster))
      cli::cli_abort("input {i} must be a {.cls LazyRaster}")
    # Inputs normally share the WHOLE grid. The one relaxation: a purely
    # spatial (y, x) input may join a cube input, so a per-pixel plane can
    # be applied across a (t/band, y, x) cube -- e.g. gating every band of
    # a stack by one QA plane. `fn` must broadcast it itself (see
    # [g_rep_t()]); nothing here reshapes. Without this the caller has to
    # apply the plane per band BEFORE stacking, which leaves the stack's
    # parents computed rather than bare sources and so blocks multi-band
    # read coalescing.
    ok <- grid_equal(xs[[1L]]@grid, x@grid) ||
      (length(.outer_dims(x@grid)) == 0L &&
         .spatial_equal(xs[[1L]]@grid, x@grid))
    if (!ok)
      cli::cli_abort(paste0(
        "input {i} is not on the same grid ",
        "({grid_diff(xs[[1L]]@grid, x@grid)}); {.fn align} it first"))
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
      cli::cli_abort(paste0(
        "layer {i} is not on the same grid ",
        "({grid_diff(xs[[1L]]@grid, x@grid)}); {.fn align} it first"))
    if (identical(graph@nodes, x@graph@nodes)) x@node_id
    else graph_import(graph, x@graph, x@node_id)
  }, integer(1))

  grids <- lapply(seq_along(ids), function(i) graph_get(graph, ids[[i]])@grid)
  node_tmp <- StackNode(id = 0L, parents = ids, grid = grids[[1L]],
                        along = along)
  grid <- output_grid(node_tmp, grids)
  # Layer names become the stacked axis's labels (slice dates on t,
  # band names on band): metadata the planner never reads, carried so
  # label selection / labelled output / dt-aware scans stay possible
  # downstream. Unnamed lists leave the grid unlabelled, as before.
  grid <- .grid_relabel(grid, along, names(xs))
  id <- graph_add(
    graph,
    StackNode,
    parents = ids,
    grid    = grid,
    along   = along
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

# Label selection on a stacked axis. The raster must be a lazy_stack
# along `axis` with labels (layer names) on it; selection rebuilds the
# stack from the matching parents, so downstream planning sees an
# ordinary (smaller) StackNode.
.axis_sel <- function(x, axis, sel) {
  .assert_class(x, LazyRaster, "LazyRaster")
  labs <- x@grid@labels[[axis]]
  if (is.null(labs))
    cli::cli_abort(c(
      "no {.val {axis}} labels on this raster.",
      "i" = paste0("labels come from the layer NAMES given to ",
                   "{.fn lazy_stack} (or a dataset's slice dates)")))
  node <- graph_get(x@graph, x@node_id)
  if (!S7::S7_inherits(node, StackNode) || !identical(node@along, axis))
    cli::cli_abort(paste0(
      "label selection needs the raster to be a {.fn lazy_stack} ",
      "along {.val {axis}} (got {.cls {class(node)[[1L]]}})"))
  keep <- if (is.character(sel)) {
    m <- labs %in% sel                       # exact labels first
    if (!any(m))                             # else prefix ("2023-06")
      m <- Reduce(`|`, lapply(sel, function(s) startsWith(labs, s)))
    which(m)
  } else if (is.logical(sel)) {
    which(rep_len(sel, length(labs)))
  } else {
    as.integer(sel)
  }
  if (!length(keep) || any(keep < 1L) || any(keep > length(labs)))
    cli::cli_abort("no {.val {axis}} slices match {.val {sel}}")
  if (length(keep) == 1L) {
    pid <- node@parents[[keep]]
    return(LazyRaster(graph = x@graph, node_id = pid,
                      grid = graph_get(x@graph, pid)@grid))
  }
  layers <- lapply(node@parents[keep], function(pid)
    LazyRaster(graph = x@graph, node_id = pid,
               grid = graph_get(x@graph, pid)@grid))
  lazy_stack(stats::setNames(layers, labs[keep]), along = axis)
}

#' Select time slices of a stacked raster by label.
#'
#' Label selection on the `t` axis (the `.sel(time = ...)` analog):
#' exact label matches, or prefix matches for partial datetime strings
#' (`"2023-06"` selects every June slice), or integer/logical positions.
#' The raster must be a `lazy_stack` along `t` whose layers were named
#' (slice dates); a single match returns the bare layer.
#'
#' @param x A `LazyRaster` stacked along `t` with labels.
#' @param sel Character labels/prefixes, or integer/logical positions.
#' @return A `LazyRaster` (the sub-stack, or the single matching layer).
#' @export
time_sel <- function(x, sel) .axis_sel(x, "t", sel)

#' Select bands of a stacked raster by label.
#'
#' As [time_sel()], on the `band` axis.
#'
#' @param x A `LazyRaster` stacked along `band` with labels.
#' @param sel Character labels/prefixes, or integer/logical positions.
#' @return A `LazyRaster`.
#' @export
band_sel <- function(x, sel) .axis_sel(x, "band", sel)

# ---------------------------------------------------------------------------
# Operators
# ---------------------------------------------------------------------------

# Binary op helper. Grid mismatch errors (align stays explicit, decision
# D8's cousin); graph mismatch auto-merges by importing b's subgraph into
# a's graph (decision D6) — users never manage graphs by hand.
.lazy_binop <- function(a, b, op, divide = FALSE, dtype = NULL) {
  if (!grid_equal(a@grid, b@grid))
    cli::cli_abort(paste0(
      "grids differ ({grid_diff(a@grid, b@grid)}); ",
      "use {.code align(a, b, to = ...)} first"))
  graph <- a@graph
  b_id <- if (identical(graph@nodes, b@graph@nodes)) b@node_id
          else graph_import(graph, b@graph, b@node_id)
  grid <- .grid_retype(
    a@grid,
    dtype %||% dtype_promote(a@grid@dtype, b@grid@dtype, divide = divide))
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
.lazy_scalar_op <- function(lr, s, op, scalar_first, divide = FALSE,
                            dtype = NULL) {
  fn <- if (scalar_first) function(x) op(s, x) else function(x) op(x, s)
  grid <- .grid_retype(
    lr@grid,
    dtype %||% dtype_promote(lr@grid@dtype, lr@grid@dtype, divide = divide))
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

# Comparisons produce f32 0/1 masks, not logical: the map-algebra
# masking idiom then composes directly ((x > 5) * y, mask sums, ...).
for (op_name in c(">", "<", ">=", "<=", "==", "!=")) {
  op_fn <- get(op_name, envir = baseenv())
  S7::method(op_fn, list(LazyRaster, LazyRaster)) <-
    local({
      f <- op_fn
      function(e1, e2) .lazy_binop(
        e1, e2, function(x, y) g_cast(f(x, y), "f32"), dtype = "f32")
    })
  S7::method(op_fn, list(LazyRaster, S7::class_numeric)) <-
    local({
      f <- op_fn
      function(e1, e2) .lazy_scalar_op(
        e1, e2, function(x, y) g_cast(f(x, y), "f32"), FALSE, dtype = "f32")
    })
  S7::method(op_fn, list(S7::class_numeric, LazyRaster)) <-
    local({
      f <- op_fn
      function(e1, e2) .lazy_scalar_op(
        e2, e1, function(x, y) g_cast(f(x, y), "f32"), TRUE, dtype = "f32")
    })
}

# ^ promotes to float (R's semantics: int^int is double); %% keeps the
# input dtype.
for (op_name in c("^", "%%")) {
  op_fn <- get(op_name, envir = baseenv())
  is_pow <- op_name == "^"
  S7::method(op_fn, list(LazyRaster, LazyRaster)) <-
    local({
      f <- op_fn; d <- is_pow
      function(e1, e2) .lazy_binop(e1, e2, f, divide = d)
    })
  S7::method(op_fn, list(LazyRaster, S7::class_numeric)) <-
    local({
      f <- op_fn; d <- is_pow
      function(e1, e2) .lazy_scalar_op(e1, e2, f, FALSE, divide = d)
    })
  S7::method(op_fn, list(S7::class_numeric, LazyRaster)) <-
    local({
      f <- op_fn; d <- is_pow
      function(e1, e2) .lazy_scalar_op(e2, e1, f, TRUE, divide = d)
    })
}

# Math group generic (sqrt, log, exp, abs, floor, sin, ...): one
# elementwise MapNode over the g_-compatible base function. cum*
# members need an axis and are refused (scan_over is that verb).
# Registered as an S3 group method in NAMESPACE (S7 instances carry
# class "garry::LazyRaster").
.lazy_math <- function(x, generic, ...) {
  if (startsWith(generic, "cum"))
    cli::cli_abort(paste0(
      "{.fn ", generic, "} is cumulative; use {.fn scan_over} ",
      "for running values along an axis"))
  fn <- get(generic, envir = baseenv())
  dots <- list(...)
  keeps_dtype <- generic %in% c("abs", "sign", "floor", "ceiling",
                                "trunc", "round", "signif")
  body_fn <- if (length(dots)) function(v) do.call(fn, c(list(v), dots))
             else function(v) fn(v)
  dtype <- if (S7::S7_inherits(x, LazyRaster) && !keeps_dtype)
    dtype_promote(x@grid@dtype, x@grid@dtype, divide = TRUE)
  lazy_map(x, fn = body_fn, dtype = dtype)
}

#' @rawNamespace S3method(Math, "garry::LazyRaster", .lazy_math_raster)
.lazy_math_raster <- function(x, ...) .lazy_math(x, .Generic, ...)

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
#' `boundary = "nodata"` policy; reflect/wrap remain unimplemented
#' (deliberately deferred, not scheduled).
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

#' Shrink the valid-data footprint by a pixel margin.
#'
#' Sets to NaN every pixel within `radius` pixels of nodata, eroding
#' each nodata boundary (scene footprint edges, cloud-mask holes, the
#' raster border) by that margin. The standard cure for corrupt scene
#' edges: satellite granules commonly carry one or two pixels of bad
#' radiometry just inside their data footprint that QA masks miss, and
#' on a `(t, y, x)` stack each slice's footprint erodes independently.
#'
#' Implemented as a [focal()] kernel (centre plus zero times the window
#' sum, which is NaN wherever any neighbour is NaN), so it plans and
#' fuses like any stencil, and applies per band over a `LazyDataset`.
#'
#' @param x A `LazyRaster`, or a `LazyDataset`.
#' @param radius Margin to remove, in pixels.
#' @param bands `LazyDataset` only: bands to apply to (default: all
#'   value bands).
#' @return The eroded object, same class and grid as `x`.
#' @export
shrink_footprint <- function(x, radius = 1L, bands = NULL) {
  radius <- as.integer(radius)
  if (length(radius) != 1L || is.na(radius) || radius < 1L)
    cli::cli_abort("{.arg radius} must be a positive integer")
  focal(x, radius = radius, bands = bands,
        fn = function(sh) sh[[(length(sh) + 1L) %/% 2L]] + 0 * Reduce(`+`, sh))
}

#' A bilateral (edge-preserving) focal body for [focal()].
#'
#' Returns a focal `fn(shifts)` computing the classic bilateral filter:
#' each output pixel is the window mean weighted by a spatial Gaussian
#' (distance from the centre, `sigma_d`) times a range Gaussian
#' (difference from the centre VALUE, `sigma_r`), so smoothing stays
#' within regions of similar value and stops at sharp transitions. Use
#' as `focal(x, fn = bilateral_focal(sigma_r), radius = 1L)`.
#'
#' Semantics match `rustyfilters::rf_bilateral(edge = "shrink",
#' na_policy = "omit")`: a NaN centre stays NaN; NaN neighbours (and the
#' NaN halo garry pads outside the raster) drop out of the weighted
#' mean. `sigma_r` must be supplied: the parameter-free per-band default
#' (the band's own sd) is a whole-raster statistic, so compute it in a
#' separate reduce pass (or reuse fitted values) and pass it in.
#'
#' @param sigma_r Range Gaussian standard deviation (data units).
#' @param sigma_d Spatial Gaussian standard deviation in pixels
#'   (default 1, hutan's `(window - 1) / 2` for a 3x3 window).
#' @param radius Window radius the body is built for; must match the
#'   `radius` passed to [focal()] (default 1 = 3x3).
#' @return A focal body `fn(shifts)` for [focal()].
#' @export
bilateral_focal <- function(sigma_r, sigma_d = 1, radius = 1L) {
  if (!is.numeric(sigma_r) || length(sigma_r) < 1L ||
      !all(is.finite(sigma_r)) || any(sigma_r <= 0))
    cli::cli_abort("{.arg sigma_r} must be finite positive (scalar or per-channel vector)")
  if (!is.numeric(sigma_d) || length(sigma_d) != 1L ||
      !is.finite(sigma_d) || sigma_d <= 0)
    cli::cli_abort("{.arg sigma_d} must be a finite positive scalar")
  r <- as.integer(radius)
  # spatial weights in focal()'s shift order (expand.grid(dx, dy) row-major)
  off <- expand.grid(dx = -r:r, dy = -r:r)
  sw <- exp(-(off$dx^2 + off$dy^2) / (2 * sigma_d^2))
  inv2sr2 <- 1 / (2 * sigma_r^2)
  # Per-channel sigmas (length > 1): the body runs on a (channel, y, x)
  # cube and the inverse-variance broadcasts along the leading axis, so
  # ONE FocalNode filters every channel with its own range sigma.
  per_channel <- length(sigma_r) > 1L
  force(inv2sr2); force(per_channel)
  function(shifts) {
    inv2 <- if (!per_channel) inv2sr2 else {
      centre0 <- shifts[[(length(shifts) + 1L) %/% 2L]]
      rank <- if (.g_traced(centre0)) length(.g_shape(centre0))
              else length(dim(centre0))
      if (rank < 3L)
        cli::cli_abort("per-channel sigma_r needs a (channel, y, x) cube input")
      a <- array(inv2sr2, c(length(inv2sr2), rep(1L, rank - 1L)))
      if (.g_traced(centre0)) g_upload(a, "f32") else a
    }
    if (length(shifts) != length(sw))
      cli::cli_abort("bilateral_focal(radius = {r}) got {length(shifts)} shifts; pass the same radius to focal()")
    centre <- shifts[[(length(shifts) + 1L) %/% 2L]]
    num <- 0
    den <- 0
    for (s in seq_along(shifts)) {
      v <- shifts[[s]]
      d2 <- (v - centre)^2
      w <- if (per_channel) {
        b <- g_broadcast_arrays(d2, inv2)
        sw[[s]] * exp(-b[[1L]] * b[[2L]])
      } else {
        sw[[s]] * exp(-d2 * inv2)
      }
      ok <- !g_is_nodata(v)
      wv <- g_ifelse(ok, w, 0)
      num <- num + wv * g_ifelse(ok, v, 0)
      den <- den + wv
    }
    # NaN centre: the range weight is NaN at every valid neighbour, so
    # num/den is NaN, matching rf_bilateral. A valid centre always
    # contributes weight sw > 0, so den > 0 there.
    num / den
  }
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

#' Scan along an axis, keeping it (temporal recursions).
#'
#' The length-preserving sibling of [reduce_over()]: carry state
#' sequentially along `over` while emitting a same-length series
#' (Kalman smoothers, EWMA, IIR filters, cumulative custom ops). The
#' output grid is the input grid unchanged; only the dtype may differ.
#'
#' `fn` is the scan body `fn(xs, margin) -> y`, written in the
#' `g_*` vocabulary and typically built around [g_scan()]: `xs` is the
#' LIST of parent chunk values (pass a list of LazyRasters on the same
#' grid to scan several cubes in lockstep), `margin` is the scanned
#' axis position, and `y` has the shape of `xs[[1]]`. Like a custom
#' reducer, a scan holds the full `over` axis per spatial chunk, so it
#' is supported over `"t"`/`"band"` only.
#'
#' Over a `LazyDataset`, each band's slices are stacked along `"t"` and
#' scanned independently (`bands` restricts which).
#'
#' @param x A `LazyRaster`, a list of `LazyRaster`s on the same graph
#'   and grid (multi-input scan), or a `LazyDataset`.
#' @param fn Scan body `fn(xs, margin)`.
#' @param over Single dim name to scan along (default `"t"`).
#' @param direction `"forward"`, `"backward"`, or `"bidir"` (the body
#'   encapsulates direction; this is declarative metadata).
#' @param dtype Optional output dtype override (default: input dtype).
#' @param bands `LazyDataset` only: bands to scan (default: all).
#' @return A `LazyRaster` on the unchanged grid, or a `LazyDataset`.
#' @export
scan_over <- function(x, fn, over = "t", direction = "forward",
                      dtype = NULL, bands = NULL) {
  if (S7::S7_inherits(x, LazyDataset))
    return(.ds_scan(x, fn, over, direction, dtype, bands))
  xs <- if (is.list(x)) x else list(x)
  for (lr in xs) .assert_class(lr, LazyRaster, "LazyRaster")
  lead <- xs[[1L]]
  graph <- lead@graph
  parents <- vapply(xs, function(lr) {
    if (!grid_equal(lead@grid, lr@grid))
      cli::cli_abort(paste0(
        "all scan inputs must share one grid ",
        "({grid_diff(lead@grid, lr@grid)})"))
    if (identical(graph@nodes, lr@graph@nodes)) lr@node_id
    else graph_import(graph, lr@graph, lr@node_id)
  }, integer(1))
  if (!is.function(fn))
    cli::cli_abort("{.arg fn} must be a scan body function {.code fn(xs, margin)}")
  if (length(over) != 1L || !over %in% names(lead@grid@dims))
    cli::cli_abort("{.arg over} must name one dim of the input grid")
  grid <- if (is.null(dtype)) lead@grid else .grid_retype(lead@grid, dtype)
  id <- graph_add(
    graph,
    ScanNode,
    parents   = parents,
    grid      = grid,
    over      = over,
    direction = direction,
    fn        = list(fn),
    dtype     = dtype %||% character(0)
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
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
