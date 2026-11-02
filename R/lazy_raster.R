#' @include graph.R node.R grid.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# LazyRaster: user-facing array-like over the IR graph.
#
# Thin wrapper around (graph, node_id, grid). Operators add nodes and
# return new LazyRasters sharing the graph. Users never see the IR.
# ---------------------------------------------------------------------------

#' Lazy raster array (single band stack).
#'
#' Users obtain one via [lazy_source()] or [lazy_dataset()]
#' band access, and materialise it with [collect()]; the constructor itself
#' is rarely called directly.
#'
#' @param graph The shared intermediate representation (IR) `Graph`.
#' @param node_id Integer id of this raster's node.
#' @param grid Cached `GridSpec` for fast dim/crs access.
#' @return A `LazyRaster`.
#' @export
LazyRaster <- S7::new_class(
  "LazyRaster",
  properties = list(
    graph = Graph,
    node_id = S7::class_integer,
    grid = GridSpec
  )
)

# Friendly type guard for public entry points.
.assert_class <- function(
  x,
  cls,
  name,
  arg = rlang::caller_arg(x),
  call = rlang::caller_env()
) {
  if (!S7::S7_inherits(x, cls)) {
    cli::cli_abort("{.arg {arg}} must be a {.cls {name}}.", call = call)
  }
}

# GDAL resampling names garry passes to the warper and RasterIO. Checked
# when the node is built, so a typo fails here rather than inside GDAL.
.resampling_methods <- c(
  "near", "nearest", "bilinear", "cubic", "cubicspline", "lanczos",
  "average", "rms", "mode", "max", "min", "med", "q1", "q3", "sum"
)
.check_resampling <- function(resampling, arg = "resampling", call = rlang::caller_env()) {
  if (!is.character(resampling) || length(resampling) != 1L ||
      !resampling %in% .resampling_methods) {
    cli::cli_abort(
      "{.arg {arg}} must be one of {.val {(.resampling_methods)}}, not {.val {resampling}}.",
      call = call
    )
  }
  resampling
}

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

#' Build a LazyRaster from a GDAL source.
#'
#' Grid, dtype, native block size, and file nodata come from GDAL via
#' the adapter (`gdal_grid_spec()`). A user-supplied `nodata` overrides
#' the file's. An integer source with nodata is promoted to the float
#' that holds it (f32 up to 16 bits, else f64) so NaN can carry nodata
#' downstream; the sentinel-to-NaN rewrite happens at read time in the
#' adapter. An integer source without nodata has nowhere to put a missing
#' cell, so a compute stage that meets one (a failed read, a cell no tile
#' reaches, a cell a warp leaves past the source's footprint) fails: declare
#' `nodata` where cells can be missing. An Int32 cell holding `-2147483648`
#' reads as missing, `nodata` or not: gdalraster returns R integers, and that
#' value is R's `NA_integer_`.
#'
#' Passing `grid` skips the GDAL open entirely: no metadata is read
#' until execution. Use it when the dataset's grid is known by
#' construction, e.g. GTI mosaics pinned to a target grid via
#' [gti_open_options()], where opening every time slice just to
#' rediscover the grid costs a serial remote COG header fetch per
#' slice. `grid` must describe the dataset exactly as `path` +
#' `open_options` open it, including the source dtype; it is trusted,
#' not checked. With `grid` given, file nodata is NOT consulted, though a
#' read still masks it (pass `nodata` explicitly if the source has a
#' sentinel), and a warp opens the
#' file: only a source that has been opened can show that it stores the
#' same type and row order as the file whose warped VRT it would take.
#'
#' @param path Path or VSI URL readable by GDAL. A relative path is taken
#'   against the working directory here, so a later [setwd()] or a pool
#'   started elsewhere reads the same file.
#' @param band 1-based band index.
#' @param graph `Graph` to add the source to; defaults to a fresh graph.
#' @param nodata Optional nodata sentinel replacing the file's: cells
#'   holding the file's own sentinel then read as data. A tile index, a
#'   source opened with `open_options` and a source given its `grid` mask
#'   their own sentinel as well.
#' @param open_options GDAL open options ("KEY=VALUE"), e.g. a GTI
#'   `FILTER` selecting one time slice of a tile index. They apply to one
#'   source, and not to a decoded one.
#' @param grid Optional `GridSpec` declaring the source's grid and
#'   dtype, skipping metadata discovery (see Details).
#' @param block_dim Optional native block size (x, y), only meaningful
#'   with `grid`; defaults to unconstrained.
#' @param resampling GDAL resampling used when a read reprojects or rescales
#'   this source onto the analysis grid. `"near"` (default) preserves exact
#'   source values; use `"bilinear"`, `"average"`, `"cubic"`, ... to interpolate.
#' @param scale Apply the band's scale/offset at read. `FALSE` (default)
#'   reads raw values. `TRUE` discovers the affine from the file's band
#'   metadata (the GDAL scale/offset QGIS applies) and every read returns
#'   `v * scale + offset`, applied after the nodata sentinel becomes NaN.
#'   A length-1 numeric supplies the scale explicitly (with `offset`),
#'   skipping discovery. Discovery only consults the file: STAC-side
#'   metadata is never read. A band that reports none warns and reads raw.
#' @param offset Explicit additive offset used when `scale` is numeric;
#'   defaults to 0. Ignored when `scale` is logical.
#' @param name Optional display name (e.g. the asset or band name).
#'   Pure metadata: surfaced by [plan_view()] and diagnostics, never
#'   read by the planner or executors. [lazy_dataset()] sets it to the
#'   asset/band name automatically.
#' @param decode Optional function decoding the band's 8-bit codes
#'   before any resampling, as in [lazy_dataset()]; `nodata` is then the
#'   code to mask.
#' @return A `LazyRaster`.
#' @seealso [collect()], [lazy_dataset()]
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' red
#' dim(red)
#' @export
lazy_source <- function(
  path,
  band = 1L,
  graph = graph_new(),
  nodata = NULL,
  open_options = character(0),
  grid = NULL,
  block_dim = NULL,
  resampling = "near",
  scale = FALSE,
  offset = NULL,
  name = NULL,
  decode = NULL
) {
  if (!is.numeric(band) || length(band) != 1L || is.na(band) || band < 1 || band != round(band)) {
    cli::cli_abort(c(
      "{.arg band} must be one whole band number from 1, not {.val {band}}.",
      "i" = "{.fn lazy_dataset} reads several bands of a file."
    ))
  }
  if (length(open_options) && (length(path) > 1L || !is.null(decode))) {
    cli::cli_abort(c(
      "{.arg open_options} apply to one plain source.",
      "i" = "Open each source on its own, without {.arg decode}, and combine them on a common grid."
    ), class = c("garry_source_error", "garry_error"))
  }
  # A decoded source reads its lookup-table VRT (Float32, nodata NaN);
  # lazy_dataset() prepares the decode once for all its bands.
  if (!is.null(decode)) {
    if (!inherits(decode, "garry_decode")) {
      if (!isFALSE(scale) || !is.null(offset)) {
        cli::cli_abort(
          "{.arg decode} and {.arg scale}/{.arg offset} do not combine."
        )
      }
      if (is.null(block_dim)) {
        # chunks snap to the codes' blocks, not the VRT's
        block_dim <- gdal_grid_spec(
          path[[1L]],
          band = as.integer(band)
        )$block_dim
      }
      decode <- .decode_prepare(path, decode, nodata)
      nodata <- NULL
      # a given grid describes the codes; the decoded values are f32
      if (!is.null(grid)) {
        grid <- .grid_retype(grid, "f32")
      }
    }
    path <- decode$vrt
  }
  if (is.null(grid)) {
    meta <- gdal_grid_spec(
      path[[1L]],
      band = as.integer(band),
      open_options = open_options
    )
    grid <- meta$grid
    nodata <- if (is.null(nodata)) meta$nodata else as.numeric(nodata)
    path <- .source_for_nodata(path, meta$nodata, nodata, open_options)
    block_dim <- if (is.null(block_dim)) {
      meta$block_dim
    } else {
      as.integer(block_dim)
    }
  } else {
    .assert_class(grid, GridSpec, "GridSpec")
    nodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
    block_dim <- if (is.null(block_dim)) integer(0) else as.integer(block_dim)
    meta <- NULL
  }
  aff <- .resolve_scale(
    scale,
    offset,
    function() {
      if (is.null(meta)) {
        meta <<- gdal_grid_spec(
          path[[1L]],
          band = as.integer(band),
          open_options = open_options
        )
      }
      meta
    },
    what = path
  )
  if (
    (length(nodata) == 1L || length(aff$scale) == 1L) &&
      .dtype_family(grid@dtype) != "float"
  ) {
    grid <- .grid_retype(grid, .exact_float(grid@dtype))
  }
  id <- graph_add(
    graph,
    SourceNode,
    parents = integer(0),
    grid = grid,
    path = .gdal_absolute(path),
    band = as.integer(band),
    nodata = nodata,
    block_dim = block_dim,
    open_options = open_options,
    resampling = .check_resampling(resampling),
    scale = aff$scale,
    offset = aff$offset,
    name = if (is.null(name)) character(0) else as.character(name),
    decode = if (is.null(decode)) {
      list()
    } else {
      unclass(decode)[c("src", "lo", "table", "nodata")]
    },
    stored = meta$stored %||% list()
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

# Resolve a lazy_source()/lazy_dataset() `scale` argument to a normalised
# affine: list(scale, offset), both length 0 (absent) or both length 1.
# `probe` is a zero-arg closure returning a gdal_grid_spec() list, called
# only when scale = TRUE needs discovery. That warns, and does not
# abort, where the band reports none: a file declaring the identity
# (1, 0) reads back the same as one with no scale at all, so raw values
# may be right.
.resolve_scale <- function(scale, offset, probe, what) {
  if (isFALSE(scale)) {
    return(list(scale = numeric(0), offset = numeric(0)))
  }
  if (isTRUE(scale)) {
    meta <- probe()
    if (length(meta$scale) != 1L) {
      cli::cli_warn(
        c(
          "{.arg scale}: no scale/offset metadata on {.file {what}}; reading raw values.",
          "i" = "Pass the scale yourself, or {.code scale = FALSE} if these values need none."
        ),
        class = c("garry_scale_warning", "garry_warning")
      )
      return(list(scale = numeric(0), offset = numeric(0)))
    }
    return(list(scale = meta$scale, offset = meta$offset))
  }
  if (!is.numeric(scale) || length(scale) != 1L || !is.finite(scale)) {
    cli::cli_abort(
      "{.arg scale} must be `FALSE`, `TRUE`, or a finite length-1 numeric.",
      class = c("garry_source_error", "garry_error")
    )
  }
  off <- if (is.null(offset)) 0 else as.numeric(offset)
  if (length(off) != 1L || !is.finite(off)) {
    cli::cli_abort(
      "{.arg offset} must be a finite length-1 numeric.",
      class = c("garry_source_error", "garry_error")
    )
  }
  if (scale == 1 && off == 0) {
    return(list(scale = numeric(0), offset = numeric(0)))
  }
  list(scale = as.numeric(scale), offset = off)
}

#' Elementwise map over one or more aligned rasters.
#'
#' `fn` receives one traced array per input raster and returns one
#' array; it runs fused with adjacent operations in one compiled
#' kernel. Write it with plain arithmetic and the `g_*` vocabulary
#' ([g_ifelse()], [g_bitand()], [g_cast()], ...). Inputs must share a
#' grid ([align_to()] first otherwise); rasters on different graphs merge
#' automatically.
#'
#' The output dtype is the dtype `fn` returns, found by tracing it on
#' abstract inputs (nothing runs and nothing compiles). `dtype` overrides
#' it: the kernel's output is cast to `dtype`, which truncates a float to
#' an integer dtype and saturates at the ends of an unsigned one, and
#' everything downstream reads the cast value. A
#' kernel returning a logical stores 0/1 at the promoted input dtype, and
#' [g_ifelse()] reads such a mask with nonzero as true.
#'
#' Over a `LazyDataset`, `fn` is applied to every value band (a single dataset
#' input only); `bands` restricts which bands, and non-selected bands pass
#' through unchanged.
#'
#' @param ... `LazyRaster` inputs (at least one), or a single `LazyDataset`.
#' @param fn Function of as many arrays as there are inputs.
#' @param dtype Optional output dtype. Given, `fn` is not traced when the
#'   raster is built, so a kernel that only traces at chunk time can use it.
#'   Left out, it is what `fn` returns. Unsigned inputs compute in a wider
#'   signed dtype (`u8` in `i16`, `u16` in `i32`), so `fn` over them returns
#'   that unless told otherwise.
#' @param bands `LazyDataset` only: bands to map over (default: all value bands).
#' @return A `LazyRaster`, or a `LazyDataset` when given one.
#' @seealso [collect()]
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' nir <- lazy_source(f, band = 3L)
#' ndvi <- lazy_map(nir, red, fn = function(n, r) (n - r) / (n + r))
#' range(collect(ndvi))
#' @export
lazy_map <- function(..., fn, dtype = NULL, bands = NULL) {
  xs <- list(...)
  stopifnot(length(xs) >= 1L, is.function(fn))
  if (S7::S7_inherits(xs[[1L]], LazyDataset)) {
    return(.ds_map(xs, fn, dtype, bands))
  }
  .assert_class(xs[[1L]], LazyRaster, "LazyRaster", arg = "...")
  graph <- xs[[1L]]@graph
  ids <- vapply(
    seq_along(xs),
    function(i) {
      x <- xs[[i]]
      if (!S7::S7_inherits(x, LazyRaster)) {
        cli::cli_abort("input {i} must be a {.cls LazyRaster}")
      }
      # Inputs normally share the WHOLE grid. The one relaxation: a purely
      # spatial (y, x) input may join a cube input, so a per-pixel plane can
      # be applied across a (t/band, y, x) cube -- e.g. gating every band of
      # a stack by one QA plane. `fn` must broadcast it itself (see
      # [g_rep_t()]); nothing here reshapes. Without this the caller has to
      # apply the plane per band BEFORE stacking, which leaves the stack's
      # parents computed rather than bare sources and so blocks multi-band
      # read coalescing.
      ok <- grid_equal(xs[[1L]]@grid, x@grid) ||
        (length(.grid_outer(x@grid)) == 0L &&
          .spatial_equal(xs[[1L]]@grid, x@grid))
      if (!ok) {
        cli::cli_abort(paste0(
          "input {i} is not on the same grid ",
          "({grid_diff(xs[[1L]]@grid, x@grid)}); {.fn align_to} it first"
        ))
      }
      graph_import(graph, x@graph, x@node_id)
    },
    integer(1)
  )

  grids <- lapply(ids, function(i) graph_get(graph, i)@grid)
  grid <- .grid_retype(
    xs[[1L]]@grid,
    dtype %||% Reduce(dtype_promote, vapply(grids, function(g) g@dtype, character(1)))
  )
  if (is.null(dtype)) {
    probe <- MapNode(id = 0L, parents = ids, grid = grid, fn = fn)
    grid <- .grid_retype(grid, .node_dtype(probe, grids))
  }
  id <- graph_add(
    graph,
    MapNode,
    parents = ids,
    grid = grid,
    fn = fn,
    dtype = dtype %||% character(0)
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

#' Stack aligned rasters along a new outer dim (default time).
#'
#' All layers must share the spatial grid ([align_to()] first otherwise);
#' dtypes promote to a common type. Chunks carry the stack as
#' (t, y, x) arrays; temporal reductions
#' (`reduce_over(x, "median", "t")`) then run chunk-locally.
#'
#' Element names of `xs` become labels on the new axis (slice dates on
#' `t`, band names on `band`), used by [time_sel()] / [band_sel()] for
#' label selection; an unnamed list leaves the axis unlabelled.
#'
#' @param xs List of `LazyRaster`s on one grid.
#' @param along Name of the new dim ("t" or "band").
#' @return A `LazyRaster` with an extra dim.
#' @export
lazy_stack <- function(xs, along = "t") {
  stopifnot(is.list(xs), length(xs) >= 1L)
  along <- rlang::arg_match(along, c("t", "band"))
  graph <- xs[[1L]]@graph
  ids <- vapply(
    seq_along(xs),
    function(i) {
      x <- xs[[i]]
      if (!S7::S7_inherits(x, LazyRaster)) {
        cli::cli_abort("layer {i} must be a {.cls LazyRaster}")
      }
      if (!grid_equal(xs[[1L]]@grid, x@grid)) {
        cli::cli_abort(paste0(
          "layer {i} is not on the same grid ",
          "({grid_diff(xs[[1L]]@grid, x@grid)}); {.fn align_to} it first"
        ))
      }
      graph_import(graph, x@graph, x@node_id)
    },
    integer(1)
  )

  grids <- lapply(seq_along(ids), function(i) graph_get(graph, ids[[i]])@grid)
  node_tmp <- StackNode(
    id = 0L,
    parents = ids,
    grid = grids[[1L]],
    along = along
  )
  grid <- output_grid(node_tmp, grids)
  # Layer names become the stacked axis's labels (slice dates on t,
  # band names on band): metadata the planner never reads, carried so
  # label selection / labelled output / dt-aware scans stay possible
  # downstream. Unnamed lists leave the grid unlabelled.
  grid <- .grid_relabel(grid, along, names(xs))
  id <- graph_add(
    graph,
    StackNode,
    parents = ids,
    grid = grid,
    along = along
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
  if (is.null(labs)) {
    cli::cli_abort(c(
      "no {.val {axis}} labels on this raster.",
      "i" = paste0(
        "labels come from the layer NAMES given to ",
        "{.fn lazy_stack} (or a dataset's slice dates)"
      )
    ))
  }
  node <- .stack_node(x@graph, x@node_id)
  if (!S7::S7_inherits(node, StackNode) || !identical(node@along, axis)) {
    cli::cli_abort(paste0(
      "label selection needs the raster to be a {.fn lazy_stack} ",
      "along {.val {axis}} (got {.cls {class(node)[[1L]]}})"
    ))
  }
  keep <- .label_keep(labs, sel, axis)
  if (length(keep) == 1L) {
    pid <- node@parents[[keep]]
    return(LazyRaster(
      graph = x@graph,
      node_id = pid,
      grid = graph_get(x@graph, pid)@grid
    ))
  }
  layers <- lapply(node@parents[keep], function(pid) {
    LazyRaster(
      graph = x@graph,
      node_id = pid,
      grid = graph_get(x@graph, pid)@grid
    )
  })
  lazy_stack(stats::setNames(layers, labs[keep]), along = axis)
}

# Positions of `labs` that `sel` selects: each character selector its
# exact label, else every label it prefixes ("2023-06"); logical or
# integer positions as given. Errors when a selector matches nothing.
.label_keep <- function(labs, sel, axis, arg = "sel") {
  if (anyNA(sel)) {
    cli::cli_abort("{.arg {arg}} must not contain NA.")
  }
  keep <- if (is.character(sel)) {
    hits <- lapply(sel, function(s) {
      ex <- which(labs == s)
      if (length(ex)) ex else which(startsWith(labs, s))
    })
    none <- sel[lengths(hits) == 0L]
    if (length(none)) {
      cli::cli_abort("no {.val {axis}} slices match {.val {none}}")
    }
    sort(unique(unlist(hits)))
  } else if (is.logical(sel)) {
    which(rep_len(sel, length(labs)))
  } else {
    as.integer(sel)
  }
  if (!length(keep) || any(keep < 1L) || any(keep > length(labs))) {
    cli::cli_abort("no {.val {axis}} slices match {.val {sel}}")
  }
  keep
}

#' Select time slices of a stacked raster or a dataset by label.
#'
#' Label selection on the `t` axis (the `.sel(time = ...)` analog):
#' each selector matches its exact label, or failing that every label it
#' prefixes (`"2023-06"` selects every June slice); the matches are
#' combined. Integer/logical positions work too. A selector that matches
#' nothing is an error.
#' A raster must be a `lazy_stack` along `t` whose layers were named
#' (slice dates); a single match returns the bare layer. A dataset keeps
#' the matching slices of every band (each band's slices are labelled by
#' date, or by the time coordinate of an N-D source such as a Zarr array).
#'
#' @param x A `LazyRaster` stacked along `t` with labels, or a
#'   `LazyDataset`.
#' @param sel Character labels/prefixes, or integer/logical positions.
#' @return A `LazyRaster` (the sub-stack, or the single matching layer),
#'   or a `LazyDataset` holding the matching slices.
#' @export
time_sel <- function(x, sel) {
  if (S7::S7_inherits(x, LazyDataset)) {
    return(.ds_time_sel(x, sel))
  }
  .axis_sel(x, "t", sel)
}

.ds_time_sel <- function(x, sel) {
  bands <- lapply(x@bands, function(slices) {
    labs <- names(slices)
    if (is.null(labs)) {
      cli::cli_abort(c(
        "no {.val t} labels on this dataset.",
        "i" = "a dataset's slices are labelled by their dates (or time coordinate)"
      ))
    }
    slices[.label_keep(labs, sel, "t")]
  })
  LazyDataset(
    graph = x@graph,
    bands = bands,
    mask_asset = x@mask_asset,
    steps = x@steps
  )
}

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

# R's int^int is double, and the node declares so. anvl's power stays at the
# integer dtype, where it wraps and truncates a negative exponent, so an
# integer operand takes the declared float first.
.float_pow <- function(dtype) {
  force(dtype)
  function(x, y) {
    if (.g_is_integer(x)) x <- g_cast(x, dtype)
    if (.g_is_integer(y)) y <- g_cast(y, dtype)
    x^y
  }
}

# Binary op helper. Grid mismatch errors (align stays explicit, decision
# D8's cousin); graph mismatch auto-merges by importing b's subgraph into
# a's graph (decision D6): users never manage graphs by hand.
.lazy_binop <- function(a, b, op, divide = FALSE, dtype = NULL) {
  if (!grid_equal(a@grid, b@grid)) {
    cli::cli_abort(paste0(
      "grids differ ({grid_diff(a@grid, b@grid)}); ",
      "put one operand on the other's grid with {.code align_to(b, to = a)} first"
    ))
  }
  graph <- a@graph
  b_id <- graph_import(graph, b@graph, b@node_id)
  grid <- .grid_retype(
    a@grid,
    dtype %||% .carrier_dtype(dtype_promote(a@grid@dtype, b@grid@dtype, divide = divide))
  )
  id <- graph_add(
    graph,
    MapNode,
    parents = c(a@node_id, b_id),
    grid = grid,
    fn = if (identical(op, `^`)) .float_pow(grid@dtype) else op
  )
  LazyRaster(graph = graph, node_id = id, grid = grid)
}

# Scalar op helper: scalar on one side. The declared dtype follows what
# the kernel computes (anvl's rules): an R integer keeps a signed raster's
# dtype and an unsigned raster's carrier, while an R double, like
# division, makes an integer raster f32. A float raster keeps its own
# float dtype either way.
.lazy_scalar_op <- function(
  lr,
  s,
  op,
  scalar_first,
  divide = FALSE,
  dtype = NULL
) {
  if (!is.numeric(s) && !is.logical(s) || length(s) != 1L || is.na(s) && !is.nan(s)) {
    cli::cli_abort(
      "a scalar operand must be a single number, not {.val {s}}; combine rasters with rasters.",
      call = rlang::caller_env(2)
    )
  }
  if (is.logical(s)) {
    s <- as.integer(s)
  }
  floats <- divide || is.double(s)
  declared <- dtype %||% .carrier_dtype(
    dtype_promote(lr@grid@dtype, lr@grid@dtype, divide = floats)
  )
  if (identical(op, `^`)) {
    op <- .float_pow(declared)
  }
  fn <- if (scalar_first) function(x) op(s, x) else function(x) op(x, s)
  .arith_map(lr, fn, declared)
}

# A map whose dtype is already known, so nothing is traced.
.arith_map <- function(x, fn, dtype) {
  grid <- .grid_retype(x@grid, dtype)
  id <- graph_add(x@graph, MapNode, parents = x@node_id, grid = grid, fn = fn)
  LazyRaster(graph = x@graph, node_id = id, grid = grid)
}

# S7 registers methods on the base arithmetic generics via double dispatch.
# We register each for (LazyRaster, LazyRaster) and the scalar mixes. / and
# ^ promote to float (R's semantics: int^int is double); %% keeps the input
# dtype.
for (op_name in c("+", "-", "*", "/", "^", "%%")) {
  op_fn <- get(op_name, envir = baseenv())
  is_div <- op_name %in% c("/", "^")
  S7::method(op_fn, list(LazyRaster, LazyRaster)) <-
    local({
      f <- op_fn
      d <- is_div
      function(e1, e2) .lazy_binop(e1, e2, f, divide = d)
    })
  S7::method(op_fn, list(LazyRaster, S7::class_numeric)) <-
    local({
      f <- op_fn
      d <- is_div
      function(e1, e2) .lazy_scalar_op(e1, e2, f, FALSE, divide = d)
    })
  S7::method(op_fn, list(S7::class_numeric, LazyRaster)) <-
    local({
      f <- op_fn
      d <- is_div
      function(e1, e2) .lazy_scalar_op(e2, e1, f, TRUE, divide = d)
    })
}

# Logical scalars combine as 0/1, like comparisons' masks.
for (op_name in c("+", "-", "*", "/", "^", "%%", ">", "<", ">=", "<=", "==", "!=")) {
  local({
    f <- get(op_name, envir = baseenv())
    S7::method(f, list(LazyRaster, S7::class_logical)) <- function(e1, e2) f(e1, as.integer(e2))
    S7::method(f, list(S7::class_logical, LazyRaster)) <- function(e1, e2) f(as.integer(e1), e2)
  })
}

# Unary +/-: S7 0.2's Ops dispatch needs two operands, so `-` and `+`
# are S3 methods. A binary call takes the same paths as the S7 methods
# registered above.
.lazy_pm <- function(op, e1, e2, generic) {
  r1 <- S7::S7_inherits(e1, LazyRaster)
  r2 <- S7::S7_inherits(e2, LazyRaster)
  scalar <- function(v) is.numeric(v) || is.logical(v)
  if (r1 && r2) {
    return(.lazy_binop(e1, e2, op))
  }
  if (r1 && scalar(e2)) {
    return(.lazy_scalar_op(e1, if (is.logical(e2)) as.integer(e2) else e2, op, FALSE))
  }
  if (r2 && scalar(e1)) {
    return(.lazy_scalar_op(e2, if (is.logical(e1)) as.integer(e1) else e1, op, TRUE))
  }
  asNamespace("S7")$base_ops[[generic]](e1, e2) # S7's own dispatch
}
#' @rawNamespace S3method("-", "garry::LazyRaster", .lazy_minus_raster)
.lazy_minus_raster <- function(e1, e2) {
  if (missing(e2)) {
    return(.arith_map(e1, function(v) -v, .carrier_dtype(e1@grid@dtype)))
  }
  .lazy_pm(`-`, e1, e2, "-")
}
#' @rawNamespace S3method("+", "garry::LazyRaster", .lazy_plus_raster)
.lazy_plus_raster <- function(e1, e2) {
  if (missing(e2)) {
    return(e1)
  }
  .lazy_pm(`+`, e1, e2, "+")
}

# Logical algebra over 0/1 f32 masks (what comparisons return): nonzero is
# true, the result is a 0/1 f32 mask, and nodata stays nodata.
.mask_of <- function(v) g_cast(v != 0, "f32")
#' @rawNamespace S3method("!", "garry::LazyRaster", .lazy_not_raster)
.lazy_not_raster <- function(x) {
  .arith_map(
    x,
    function(v) g_ifelse(g_is_nodata(v), NaN, 1 - .mask_of(v)),
    "f32"
  )
}
for (op_name in c("&", "|")) {
  local({
    both <- op_name == "&"
    combine <- function(x, y) {
      a <- .mask_of(x)
      b <- .mask_of(y)
      out <- if (both) a * b else a + b - a * b
      out <- g_ifelse(g_is_nodata(x), NaN, out)
      g_ifelse(g_is_nodata(y), NaN, out)
    }
    gen <- get(op_name, envir = baseenv())
    S7::method(gen, list(LazyRaster, LazyRaster)) <-
      function(e1, e2) .lazy_binop(e1, e2, combine, dtype = "f32")
  })
}

#' @rawNamespace S3method(Summary, "garry::LazyRaster", .lazy_summary_raster)
.lazy_summary_raster <- function(..., na.rm = FALSE) {
  gen <- .Generic
  cli::cli_abort(c(
    "{.fn {gen}} of a lazy raster is a reduction.",
    "i" = "Use {.code reduce_over(x, \"{gen}\", c(\"x\", \"y\"))} (or over {.val t}/{.val band})."
  ))
}

# Comparisons produce f32 0/1 masks, not logical: the map-algebra
# masking idiom then composes directly ((x > 5) * y, mask sums, ...).
# Nodata compares as nodata (R: NA > 5 is NA), not as a valid 0, so a
# nan_rm reduction of a mask skips it.
.cmp_nodata <- function(f) {
  force(f)
  function(x, y) {
    out <- g_cast(f(x, y), "f32")
    if (!is.numeric(x) || length(x) != 1L) out <- g_ifelse(g_is_nodata(x), NaN, out)
    if (!is.numeric(y) || length(y) != 1L) out <- g_ifelse(g_is_nodata(y), NaN, out)
    out
  }
}
for (op_name in c(">", "<", ">=", "<=", "==", "!=")) {
  op_fn <- get(op_name, envir = baseenv())
  S7::method(op_fn, list(LazyRaster, LazyRaster)) <-
    local({
      f <- op_fn
      function(e1, e2) {
        .lazy_binop(
          e1,
          e2,
          .cmp_nodata(f),
          dtype = "f32"
        )
      }
    })
  S7::method(op_fn, list(LazyRaster, S7::class_numeric)) <-
    local({
      f <- op_fn
      function(e1, e2) {
        .lazy_scalar_op(
          e1,
          e2,
          .cmp_nodata(f),
          FALSE,
          dtype = "f32"
        )
      }
    })
  S7::method(op_fn, list(S7::class_numeric, LazyRaster)) <-
    local({
      f <- op_fn
      function(e1, e2) {
        .lazy_scalar_op(
          e2,
          e1,
          .cmp_nodata(f),
          TRUE,
          dtype = "f32"
        )
      }
    })
}

# Math group generic (sqrt, log, exp, abs, floor, sin, ...): one
# elementwise MapNode over the g_-compatible base function. cum*
# members need an axis and are refused (scan_over is that verb).
# Registered as an S3 group method in NAMESPACE (S7 instances carry
# class "garry::LazyRaster").
.lazy_math <- function(x, generic, ...) {
  if (startsWith(generic, "cum")) {
    cli::cli_abort(paste0(
      "{.fn ",
      generic,
      "} is cumulative; use {.fn scan_over} ",
      "for running values along an axis"
    ))
  }
  fn <- get(generic, envir = baseenv())
  dots <- list(...)
  # round(x, digits) divides, so it leaves the integers
  keeps_dtype <- !length(dots) && generic %in%
    c("abs", "sign", "floor", "ceiling", "trunc", "round")
  digits_only <- generic == "round" && length(dots) == 1L &&
    (is.null(names(dots)) || identical(names(dots), "digits"))
  if (length(dots) && !digits_only) {
    cli::cli_abort(c(
      "{.fn {generic}} on a lazy raster takes no extra arguments.",
      "i" = "Only {.code round(x, digits)} is supported."
    ))
  }
  body_fn <- if (length(dots)) {
    d <- dots[[1L]]
    if (!is.numeric(d) || length(d) != 1L || !is.finite(d) || d != round(d)) {
      cli::cli_abort("{.arg digits} must be a single whole number.")
    }
    p10 <- 10^d
    function(v) if (.g_traced(v)) g_round(v * p10) / p10 else round(v, d)
  } else if (generic == "round") {
    # anvl has no `round` method on arrays (no `digits` support); g_round()
    # is the same round-half-even.
    function(v) if (.g_traced(v)) g_round(v) else fn(v)
  } else {
    function(v) fn(v)
  }
  if (S7::S7_inherits(x, LazyDataset)) {
    # per layer: bands may carry different dtypes
    bands <- .ds_map_layers(x, .ds_value_bands(x), function(lr) .lazy_math(lr, generic, ...))
    return(.ds_step(x, bands, "math", generic))
  }
  .arith_map(
    x,
    body_fn,
    if (keeps_dtype) {
      x@grid@dtype
    } else {
      dtype_promote(x@grid@dtype, x@grid@dtype, divide = TRUE)
    }
  )
}

#' @rawNamespace S3method(Math, "garry::LazyRaster", .lazy_math_raster)
.lazy_math_raster <- function(x, ...) .lazy_math(x, .Generic, ...)

# ---------------------------------------------------------------------------
# Methods
# ---------------------------------------------------------------------------

# The input a halo-consuming verb (focal_map, focal_kernel, lazy_patch)
# should read: everything beneath it at a float dtype. Its stage pads
# beyond the raster edge with NaN, which an integer buffer cannot hold,
# so an integer source under a window would show cells past the edge as
# 0 rather than nodata. Other consumers keep their integer reads.
.float_halo_input <- function(x) {
  g <- x@graph
  if (is.null(g@nodes$.float_copies)) {
    g@nodes$.float_copies <- new.env(parent = emptyenv())
  }
  id <- .float_copy(g, x@node_id, g@nodes$.float_copies)
  if (identical(id, x@node_id)) {
    return(x)
  }
  LazyRaster(graph = g, node_id = id, grid = graph_get(g, id)@grid)
}

# Node `id` with every integer below it, itself included, at the float
# dtype that holds it, sharing copies through `memo`. A float warp is a
# read that needs nothing below it. So is a kernel that names its float
# dtype over integers: it decodes them (QA bits, g_bitand()), so it keeps
# its integer read, whose ring beyond the raster it reads as 0, clear.
.float_copy <- function(g, id, memo) {
  key <- .key(id)
  hit <- memo[[key]]
  if (!is.null(hit)) {
    return(hit)
  }
  n <- graph_get(g, id)
  float <- .dtype_family(n@grid@dtype) == "float"
  named <- S7::S7_inherits(n, MapNode) && length(n@dtype) == 1L
  out <- id
  if (!float || !(named || S7::S7_inherits(n, WarpNode))) {
    parents <- vapply(n@parents, .float_copy, integer(1), g = g, memo = memo)
    if (!float || !identical(parents, n@parents)) {
      p <- S7::props(n)
      p$id <- NULL
      p$parents <- parents
      p$grid <- .grid_retype(n@grid, .exact_float(n@grid@dtype))
      if (S7::S7_inherits(n, WarpNode)) {
        p$target_grid <- .grid_retype(n@target_grid, p$grid@dtype)
      }
      if (length(p$dtype)) {
        p$dtype <- p$grid@dtype
      }
      out <- do.call(graph_add, c(list(g, S7::S7_class(n)), p))
    }
  }
  memo[[key]] <- out
  out
}

# A halo radius: one whole number of at least `min`.
.check_radius <- function(radius, arg = "radius", min = 0L, call = rlang::caller_env()) {
  if (
    !is.numeric(radius) || length(radius) != 1L || is.na(radius) ||
      radius < min || radius != round(radius)
  ) {
    cli::cli_abort(
      "{.arg {arg}} must be a single whole number >= {min}, not {.val {radius}}.",
      call = call
    )
  }
  as.integer(radius)
}

#' Focal (stencil) op.
#'
#' `fn` receives a LIST of (2r+1)^2 shifted arrays, row-major over
#' (dy, dx) offsets, and returns one array: the whole neighbourhood is
#' processed vectorised across every pixel at once. Write `fn` with
#' plain arithmetic and the `g_*` vocabulary ([g_ifelse()], [g_cast()],
#' ...). Example, a 3x3 sum: `function(sh) Reduce("+", sh)`.
#'
#' Cells beyond the raster edge are NaN (nodata), whatever a kernel before
#' this one made of them. An integer raster is read as a float for the
#' stencil (f32 up to 16 bits, else f64), so the edge can be NaN, and the
#' result is that float. A map that names its float `dtype` over integers
#' keeps its integer read: its kernel decodes them, and sees cells beyond
#' the edge as 0.
#'
#' Over a `LazyDataset`, the stencil is applied to every value band per slice;
#' `bands` restricts which bands.
#'
#' @param x        LazyRaster, or a `LazyDataset`.
#' @param fn       Function over the list of shifted arrays (see above).
#' @param radius   Halo in pixels (mandatory: the footprint cannot be
#'                 inferred from `fn`).
#' @param bands    `LazyDataset` only: bands to apply to (default: all value
#'                 bands).
#' @return A `LazyRaster` on the same grid as `x`, or a `LazyDataset`
#'   when given one.
#' @seealso [focal_kernel()], [bilateral_focal()], [shrink_footprint()]
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' # a 3 x 3 window mean; cells at the raster edge are NaN
#' sm <- focal_map(red, radius = 1L, fn = function(sh) Reduce(`+`, sh) / length(sh))
#' collect(sm)[1:3, 1:3]
#' @export
focal_map <- function(x, fn, radius, bands = NULL) {
  if (S7::S7_inherits(x, LazyDataset)) {
    return(.ds_focal(x, fn, radius, bands))
  }
  .assert_class(x, LazyRaster, "LazyRaster")
  radius <- .check_radius(radius)
  x <- .float_halo_input(x)
  id <- graph_add(
    x@graph,
    FocalNode,
    parents = x@node_id,
    grid = x@grid,
    fn = fn,
    radius = radius
  )
  LazyRaster(graph = x@graph, node_id = id, grid = x@grid)
}

#' Shrink the valid-data footprint by a pixel margin.
#'
#' Sets to NaN every pixel within `radius` pixels of nodata, eroding
#' each nodata boundary (scene footprint edges, cloud-mask holes) by that
#' margin. The standard cure for corrupt scene edges: satellite granules
#' commonly carry one or two pixels of bad radiometry just inside their
#' data footprint that QA masks miss, and on a `(t, y, x)` stack each
#' slice's footprint erodes independently.
#'
#' It is morphology on the nodata mask: the footprint erodes by `radius`
#' exactly as [apply_mask()]'s `dilate` grows a mask by `radius`.
#'
#' `boundary` sets what lies beyond the edge of the grid. `"nodata"` (the
#' default) treats it as nodata, so the grid's own border erodes too.
#' `"keep"` treats it as valid, so only real nodata edges erode and the
#' result keeps its full extent; use it when the data continues past the
#' analysis grid. `"keep"` applies to 2-D rasters (`(y, x)`); over a
#' `LazyDataset` it applies slice by slice.
#'
#' Implemented with focal stencils, so it plans and fuses like any
#' [focal_map()], and applies per band over a `LazyDataset`.
#'
#' @param x A `LazyRaster`, or a `LazyDataset`.
#' @param radius Margin to remove, in pixels.
#' @param bands `LazyDataset` only: bands to apply to (default: all
#'   value bands).
#' @param boundary What lies beyond the grid edge: `"nodata"` or `"keep"`.
#' @return The eroded object, same class and grid as `x`.
#' @export
shrink_footprint <- function(
  x,
  radius = 1L,
  bands = NULL,
  boundary = c("nodata", "keep")
) {
  radius <- .check_radius(radius, min = 1L)
  boundary <- rlang::arg_match(boundary)
  if (boundary == "nodata") {
    return(focal_map(x, radius = radius, bands = bands, fn = function(sh) {
      sh[[(length(sh) + 1L) %/% 2L]] + 0 * Reduce(`+`, sh)
    }))
  }
  if (S7::S7_inherits(x, LazyDataset)) {
    bands <- .ds_check_bands(x, bands)
    sel <- bands %||% .ds_value_bands(x)
    return(.ds_step(
      x,
      .ds_map_layers(x, sel, function(lr) .shrink_keep(lr, radius)),
      "focal",
      .glue("shrink r={radius} keep {cli::symbol$bullet %||% '-'} {paste(sel, collapse = ' ')}")
    ))
  }
  .assert_class(x, LazyRaster, "LazyRaster")
  .shrink_keep(x, radius)
}

# shrink_footprint(boundary = "keep"). Inside a fused kernel a halo cell
# beyond the grid and a nodata pixel are both NaN, so an in-grid
# indicator separates them: a sourceless VRT on the grid reads 0 inside
# and NaN in the halo. z marks real nodata (1) against valid data and
# beyond-grid cells (0); any marked cell within `radius` drops the pixel.
.shrink_keep <- function(x, radius) {
  if (!setequal(names(x@grid@dims), c("x", "y"))) {
    cli::cli_abort(c(
      "{.code boundary = \"keep\"} needs a 2-D (y, x) raster.",
      "i" = "Apply it before stacking, or to a {.cls LazyDataset} (per slice)."
    ))
  }
  x <- .float_halo_input(x) # the shrink writes NaN
  inside <- lazy_source(
    gdal_blank_vrt(x@grid),
    graph = x@graph,
    grid = .grid_retype(x@grid, "f32"),
    name = "grid"
  )
  z <- lazy_map(x, inside, fn = function(v, g) {
    g_ifelse(g_is_nodata(g), 0, g_ifelse(g_is_nodata(v), 1, 0))
  })
  # a stage boundary re-presents beyond-grid cells as NaN: still not nodata
  near <- focal_map(z, radius = radius, fn = function(sh) {
    Reduce(`+`, lapply(sh, function(s) g_ifelse(g_is_nodata(s), 0, s)))
  })
  lazy_map(x, near, fn = function(v, n) g_ifelse(n > 0.5, NaN, v))
}

#' Whole-window model op (advanced): apply `fn` to the whole padded chunk.
#'
#' The escape hatch behind model-inference verbs such as [ocm_mask()]:
#' where [focal_map()] materialises a shift list (unusable beyond small
#' radii), a patch op hands `fn` the whole window carrying `radius` halo
#' cells per side and crops the contaminated ring off the result. `fn`
#' must be size-preserving on the last two (spatial) dims, derive every
#' size from its input's shape, be written in the `g_*` vocabulary, and
#' reduce the leading band axis to `out_bands` channels (0 = a plain
#' 2D result). Not differentiable. [ocm_model()]-based cloud-mask
#' prediction is the in-package example of its use.
#'
#' Cells beyond the raster edge hold the nodata of `x`'s dtype (NaN for a
#' float, 0 for an integer), whatever a kernel before this one made of them.
#'
#' `kernel_id` stands in for `fn` in kernel signatures: give two calls
#' the same id ONLY if their fns are interchangeable (same weights,
#' same code). `bytes_px`/`flops_px` price the kernel for chunk sizing,
#' memory admission, and placement, which cannot introspect `fn`.
#'
#' @param x A `LazyRaster` (typically a `(band, y, x)` stack).
#' @param fn Model body `fn(xpad)`, size-preserving.
#' @param radius Halo consumed per side, pixels.
#' @param out_bands Output band count; 0 drops the band axis.
#' @param dtype Output dtype (default `"f32"`).
#' @param kernel_id Content identity of the closed-over model.
#' @param bytes_px Working-set estimate, bytes per core pixel.
#' @param flops_px Compute estimate, flops per core pixel.
#' @return A `LazyRaster` on the spatial grid (plus `out_bands` bands).
#' @export
lazy_patch <- function(
  x,
  fn,
  radius,
  out_bands = 0L,
  dtype = "f32",
  kernel_id,
  bytes_px = 512,
  flops_px = 1e4
) {
  .assert_class(x, LazyRaster, "LazyRaster")
  radius <- .check_radius(radius)
  x <- .float_halo_input(x)
  node_tmp <- PatchNode(
    id = 0L,
    parents = x@node_id,
    grid = x@grid,
    fn = fn,
    radius = radius,
    out_bands = as.integer(out_bands),
    dtype = dtype,
    kernel_id = as.character(kernel_id),
    bytes_px = as.numeric(bytes_px),
    flops_px = as.numeric(flops_px)
  )
  grid <- output_grid(node_tmp, list(x@grid))
  id <- graph_add(
    x@graph,
    PatchNode,
    parents = x@node_id,
    grid = grid,
    fn = fn,
    radius = as.integer(radius),
    out_bands = as.integer(out_bands),
    dtype = dtype,
    kernel_id = as.character(kernel_id),
    bytes_px = as.numeric(bytes_px),
    flops_px = as.numeric(flops_px)
  )
  LazyRaster(graph = x@graph, node_id = id, grid = grid)
}

#' A bilateral (edge-preserving) focal body for [focal_map()].
#'
#' Returns a focal `fn(shifts)` computing the classic bilateral filter:
#' each output pixel is the window mean weighted by a spatial Gaussian
#' (distance from the centre, `sigma_d`) times a range Gaussian
#' (difference from the centre VALUE, `sigma_r`), so smoothing stays
#' within regions of similar value and stops at sharp transitions. Use
#' as `focal_map(x, fn = bilateral_focal(sigma_r), radius = 1L)`.
#'
#' A NaN centre stays NaN; NaN neighbours (and the NaN halo garry pads
#' outside the raster) drop out of the weighted mean, so the window shrinks
#' at raster edges and around holes.
#' `sigma_r` must be supplied: the parameter-free per-band default
#' (the band's own sd) is a whole-raster statistic, so compute it in a
#' separate reduce pass (or reuse fitted values) and pass it in.
#'
#' @param sigma_r Range Gaussian standard deviation (data units).
#' @param sigma_d Spatial Gaussian standard deviation in pixels
#'   (default 1, matching the default 3x3 window).
#' @param radius Window radius the body is built for; must match the
#'   `radius` passed to [focal_map()] (default 1 = 3x3).
#' @return A focal body `fn(shifts)` for [focal_map()].
#' @export
bilateral_focal <- function(sigma_r, sigma_d = 1, radius = 1L) {
  if (
    !is.numeric(sigma_r) ||
      length(sigma_r) < 1L ||
      !all(is.finite(sigma_r)) ||
      any(sigma_r <= 0)
  ) {
    cli::cli_abort(
      "{.arg sigma_r} must be finite positive (scalar or per-channel vector)"
    )
  }
  if (
    !is.numeric(sigma_d) ||
      length(sigma_d) != 1L ||
      !is.finite(sigma_d) ||
      sigma_d <= 0
  ) {
    cli::cli_abort("{.arg sigma_d} must be a finite positive scalar")
  }
  r <- as.integer(radius)
  # spatial weights in focal_map()'s shift order (expand.grid(dx, dy) row-major)
  off <- expand.grid(dx = -r:r, dy = -r:r)
  sw <- exp(-(off$dx^2 + off$dy^2) / (2 * sigma_d^2))
  inv2sr2 <- 1 / (2 * sigma_r^2)
  # Per-channel sigmas (length > 1): the body runs on a (channel, y, x)
  # cube and the inverse-variance broadcasts along the leading axis, so
  # ONE FocalNode filters every channel with its own range sigma.
  per_channel <- length(sigma_r) > 1L
  force(inv2sr2)
  force(per_channel)
  function(shifts) {
    inv2 <- if (!per_channel) {
      inv2sr2
    } else {
      centre0 <- shifts[[(length(shifts) + 1L) %/% 2L]]
      rank <- if (.g_traced(centre0)) {
        length(.g_shape(centre0))
      } else {
        length(dim(centre0))
      }
      if (rank < 3L) {
        cli::cli_abort("per-channel sigma_r needs a (channel, y, x) cube input")
      }
      a <- array(inv2sr2, c(length(inv2sr2), rep(1L, rank - 1L)))
      if (.g_traced(centre0)) g_upload(a, "f32") else a
    }
    if (length(shifts) != length(sw)) {
      cli::cli_abort(
        "bilateral_focal(radius = {r}) got {length(shifts)} shifts; pass the same radius to focal_map()"
      )
    }
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
#' `op` is a reduction name, not a function: the planner needs op
#' identity for algebraic decomposition and dtype rules. `nan_rm = TRUE`
#' (the default) skips nodata, matching R's `na.rm = TRUE` under the
#' NaN nodata sentinel. A pixel that is nodata in every input stays
#' nodata (NaN) for `"mean"`, `"median"`, `"min"` and `"max"`; `"sum"`
#' gives 0 and `"count"` gives 0. (The [g_min()] / [g_max()] primitives
#' return their identity, `Inf` / `-Inf`, instead.)
#'
#' Over a `LazyDataset`, each band is reduced independently (over `"t"`: stack
#' the band's slices and collapse time to a composite); `bands` restricts which
#' bands. `over = "band"` collapses the band axis, returning a `LazyRaster`.
#'
#' @param x A `LazyRaster`, or a `LazyDataset`.
#' @param op Reduction name: one of `"sum"`, `"mean"`, `"min"`, `"max"`,
#'   `"median"`, `"count"`. Alternatively a custom reducer: a function
#'   `fn(x, dims)` written in the `g_*` vocabulary that collapses the
#'   margins `dims` (e.g. a per-pixel model fit over time).
#' @param over Names of dims to reduce over (subset of `names(dims)`).
#' @param nan_rm Skip NaN (nodata) values?
#' @param bands `LazyDataset` only: bands to reduce (default: all bands).
#' @return A `LazyRaster` on the reduced grid, or a `LazyDataset` when given one.
#' @seealso [geomedian()] and [medoid()] for multivariate time
#'   composites; [band_project()] and [mlp_project()] for band-axis
#'   models; [group_by_time()] for calendar-grouped reduction;
#'   [scan_over()] for order-preserving passes.
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' collect(reduce_over(red, "mean", c("x", "y")))
#' stk <- lazy_stack(list(a = red, b = red * 2))
#' dim(collect(reduce_over(stk, "median", "t")))
#' @export
reduce_over <- function(x, op, over, nan_rm = TRUE, bands = NULL) {
  if (!isTRUE(nan_rm) && !isFALSE(nan_rm)) {
    cli::cli_abort("{.arg nan_rm} must be TRUE or FALSE, not {.val {nan_rm}}.")
  }
  if (S7::S7_inherits(x, LazyDatasetGroups)) {
    return(.dsg_reduce(x, op, over, nan_rm, bands))
  }
  if (S7::S7_inherits(x, LazyDataset)) {
    return(.ds_reduce(x, op, over, nan_rm, bands))
  }
  .assert_class(x, LazyRaster, "LazyRaster")
  # A custom reducer arrives as a function: an anvl kernel `fn(x, dims)`
  # collapsing `dims` (e.g. per-pixel OLS/harmonic fit over time). Carried on
  # the node as `fn`; `op` becomes the sentinel "custom" (dtype = parent's).
  fn <- list()
  if (is.function(op)) {
    fn <- list(op)
    op <- "custom"
  }
  grid <- .reduce_grid(x@grid, op, over) # validates `over`, applies D7
  if (length(fn)) {
    probe <- ReduceNode(
      id = 0L,
      parents = x@node_id,
      grid = grid,
      op = op,
      over = over,
      nan_rm = nan_rm,
      fn = fn
    )
    grid <- .grid_retype(grid, .node_dtype(probe, list(x@grid)))
  }
  id <- graph_add(
    x@graph,
    ReduceNode,
    parents = x@node_id,
    grid = grid,
    op = op,
    over = over,
    nan_rm = nan_rm,
    fn = fn
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
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' stk <- lazy_stack(list(a = red, b = red, c = red))
#' # a running sum along t
#' cs <- scan_over(stk, over = "t", fn = function(xs, margin) {
#'   g_scan(0, function(carry, v) list(carry = carry + v, out = carry + v),
#'          xs = xs[[1L]])$out
#' })
#' dim(collect(cs))
#' @export
scan_over <- function(
  x,
  fn,
  over = "t",
  direction = "forward",
  dtype = NULL,
  bands = NULL
) {
  if (S7::S7_inherits(x, LazyDataset)) {
    return(.ds_scan(x, fn, over, direction, dtype, bands))
  }
  xs <- if (is.list(x)) x else list(x)
  for (lr in xs) {
    .assert_class(lr, LazyRaster, "LazyRaster")
  }
  lead <- xs[[1L]]
  graph <- lead@graph
  parents <- vapply(
    xs,
    function(lr) {
      if (!grid_equal(lead@grid, lr@grid)) {
        cli::cli_abort(paste0(
          "all scan inputs must share one grid ",
          "({grid_diff(lead@grid, lr@grid)})"
        ))
      }
      graph_import(graph, lr@graph, lr@node_id)
    },
    integer(1)
  )
  if (!is.function(fn)) {
    cli::cli_abort(
      "{.arg fn} must be a scan body function {.code fn(xs, margin)}"
    )
  }
  if (length(over) != 1L || !over %in% names(lead@grid@dims)) {
    cli::cli_abort("{.arg over} must name one dim of the input grid")
  }
  if (is.null(dtype)) {
    probe <- ScanNode(
      id = 0L,
      parents = parents,
      grid = lead@grid,
      over = over,
      direction = direction,
      fn = list(fn),
      dtype = character(0)
    )
    real <- .node_dtype(probe, lapply(parents, function(i) graph_get(graph, i)@grid))
    if (!identical(real, lead@grid@dtype)) {
      dtype <- real
    }
  }
  grid <- if (is.null(dtype)) lead@grid else .grid_retype(lead@grid, dtype)
  id <- graph_add(
    graph,
    ScanNode,
    parents = parents,
    grid = grid,
    over = over,
    direction = direction,
    fn = list(fn),
    dtype = dtype %||% character(0)
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
  if (!is.null(ctr) && length(ctr) != length(w)) {
    cli::cli_abort("{.arg center} must be the same length as {.arg weights}.")
  }
  force(w)
  force(ctr)
  function(x, dims) {
    rank <- if (.g_traced(x)) length(.g_shape(x)) else length(dim(x))
    lead <- function(v) {
      # v -> (length(v), 1, ..., 1)
      a <- array(as.numeric(v), c(length(v), rep(1L, rank - 1L)))
      if (.g_traced(x)) g_upload(a, "f32") else a
    }
    xc <- if (is.null(ctr)) {
      x
    } else {
      b <- g_broadcast_arrays(x, lead(ctr))
      b[[1L]] - b[[2L]]
    }
    b <- g_broadcast_arrays(xc, lead(w))
    g_sum(b[[1L]] * b[[2L]], dims)
  }
}

#' Linear focal op with an explicit kernel (differentiable).
#'
#' The kernel is a (2r+1) x (2r+1) matrix of weights; the op is the
#' weighted sum over the window. Unlike [focal_map()] with an arbitrary
#' `fn`, a kernel focal is differentiable with respect to its weights:
#' pass the returned LazyRaster as `wrt` to [lazy_value_and_grad()].
#'
#' @param x A `LazyRaster`.
#' @param weights Square odd-sided numeric matrix, rows = dy, cols = dx.
#' @return A `LazyRaster` (a float for an integer `x`, which is read as
#'   the float that holds it so cells beyond the raster edge can be NaN).
#' @export
focal_kernel <- function(x, weights) {
  .assert_class(x, LazyRaster, "LazyRaster")
  x <- .float_halo_input(x)
  weights <- as.matrix(weights)
  stopifnot(nrow(weights) == ncol(weights), nrow(weights) %% 2L == 1L)
  radius <- (nrow(weights) - 1L) %/% 2L
  # Flatten row-major over (dy, dx) to match the shift enumeration.
  w <- as.numeric(t(weights))
  id <- graph_add(
    x@graph,
    FocalNode,
    parents = x@node_id,
    grid = x@grid,
    fn = function(sh) {
      cli::cli_abort("kernel focal is evaluated from weights", .internal = TRUE)
    },
    radius = radius,
    weights = w
  )
  LazyRaster(graph = x@graph, node_id = id, grid = x@grid)
}

#' Lazily resample/reproject onto a target grid.
#'
#' Inserts an explicit warp step, executed as a GDAL VRT warp.
#' Alignment stays explicit: binary ops never auto-resample.
#'
#' A warp takes GDAL's default tolerance, 0.125 source pixels, so a cell
#' can sit that far from where the exact transform puts it. Set
#' `garry.warp_exact = TRUE` for exact warps, at about five times the cost.
#'
#' Paste fast path: when `x` is already exactly on the target grid
#' (same CRS, transform, extent and dims; `grid_equal()`), `align_to()`
#' is a no-op returning `x`: reads stay plain windowed reads, with no
#' warp barrier splitting the plan. This is the single-CRS-zone
#' workflow: pin the analysis grid to the sources' native grid and
#' nothing warps. Only EXACT equality pastes (unlike odc-stac's
#' tolerance-based `ttol`): a sub-pixel-shifted paste would silently
#' move every pixel by up to half a cell, so near-misses warp.
#'
#' @param x A `LazyRaster`.
#' @param to Target grid: a `GridSpec` or another `LazyRaster`.
#' @param resampling GDAL resampling method. The default, `"near"`,
#'   copies source values unchanged, which categorical data (land cover,
#'   classes) and QA bitmasks need: interpolating them invents classes and
#'   bit patterns that do not exist. It matches the default of
#'   [lazy_source()] and [lazy_dataset()]. For continuous data
#'   (reflectance, elevation, temperature) choose `"bilinear"` (or
#'   `"cubic"`) when resampling to a similar or finer resolution, and
#'   `"average"` when aggregating to a coarser one.
#' @return A `LazyRaster` on the target grid.
#' @examples
#' f <- system.file("extdata", "garry-example.tif", package = "garry")
#' red <- lazy_source(f, band = 1L)
#' coarse <- grid_spec(crs = grid_crs(red), extent = grid_bbox(red), dims = c(30L, 20L))
#' dim(collect(align_to(red, coarse, resampling = "average")))
#' @export
align_to <- function(x, to, resampling = "near") {
  .assert_class(x, LazyRaster, "LazyRaster")
  to_grid <- if (S7::S7_inherits(to, LazyRaster)) to@grid else to
  .assert_class(to_grid, GridSpec, "GridSpec", arg = "to")
  resampling <- .check_resampling(resampling)
  # Only `to`'s spatial geometry: x keeps its own outer axes and labels
  # (a warp of a 2-D raster onto a stack's grid is still 2-D).
  outer <- .grid_outer(x@grid)
  target <- GridSpec(
    crs = to_grid@crs,
    transform = to_grid@transform,
    extent = to_grid@extent,
    dims = c(to_grid@dims[c("x", "y")], outer),
    dtype = x@grid@dtype,
    labels = x@grid@labels
  )
  if (grid_equal(x@grid, target)) {
    return(x)
  }
  src <- graph_get(x@graph, x@node_id)
  if (!S7::S7_inherits(src, SourceNode) || length(src@band) > 1L || length(src@collapsed)) {
    .warp_refusal()
  }
  id <- graph_add(
    x@graph,
    WarpNode,
    parents = x@node_id,
    grid = target,
    target_grid = target,
    resampling = resampling
  )
  LazyRaster(graph = x@graph, node_id = id, grid = target)
}

#' Coarsen a raster or dataset by block means.
#'
#' Maps `x` onto the grid `factor` times coarser, anchored on its origin:
#' each coarse cell is the mean of the valid (non-NaN) values of its
#' `factor` x `factor` block, NaN when none is valid. This is exact block
#' arithmetic, not a GDAL resampler, so the two stages stay explicit: a
#' decoded embedding read by nearest neighbour onto a 10 m grid, then
#' averaged to 30 m,
#'
#' ```
#' codes <- lazy_dataset(tiles, grid10, resampling = "near", decode = dequantize_aef)
#' cube <- stack_bands(coarsen(codes, 3L))
#' ```
#'
#' takes, for each 30 m cell, the mean of the nine decoded 10 m values the
#' 10 m read gives, never a GDAL average over the reprojected source
#' footprint. The coarsening runs inside the read: each window's finer
#' cells are assembled from the sources as the nearest-neighbour read of
#' them assembles them (a direct window read of a source on those cells'
#' pixels, a nearest warp of any other source alone, later sources
#' winning where they hold data), decoded, and averaged in one pass, so
#' the finer grid is never written. Cells warped from a reprojected
#' source match the finer read's under `garry.warp_exact = TRUE`; with
#' GDAL's approximate transformer (the default) a cell near a pixel
#' boundary can take the neighbouring pixel.
#'
#' Version 1 coarsens reads only: `x` must come straight from
#' [lazy_dataset()] or [lazy_source()] (decoded or not) by
#' nearest-neighbour, from sources opened without open options, and its
#' dims must divide by `factor`. A dataset with a `mask_asset` is
#' refused: averaging a mask band's bits would invent flags.
#'
#' @param x A `LazyRaster` or `LazyDataset` reading its sources.
#' @param factor Integer block size (>= 1).
#' @return A `LazyRaster` or `LazyDataset` on the coarser grid (f32).
#' @export
coarsen <- function(x, factor) {
  if (
    !is.numeric(factor) ||
      length(factor) != 1L ||
      factor < 1 ||
      factor != round(factor)
  ) {
    cli::cli_abort("{.arg factor} must be a whole number >= 1.")
  }
  k <- as.integer(factor)
  if (S7::S7_inherits(x, LazyDataset)) {
    if (length(x@mask_asset)) {
      cli::cli_abort(c(
        "{.fn coarsen} would average the dataset's mask band {.val {x@mask_asset}}.",
        "i" = "Read the dataset without {.arg mask_asset}, or mask at the finer grid first."
      ))
    }
    bands <- lapply(x@bands, function(slices) {
      lapply(slices, coarsen, factor = k)
    })
    return(LazyDataset(
      graph = x@graph,
      bands = bands,
      mask_asset = x@mask_asset,
      steps = x@steps
    ))
  }
  .assert_class(x, LazyRaster, "LazyRaster")
  n <- graph_get(x@graph, x@node_id)
  src_id <- NULL
  if (S7::S7_inherits(n, WarpNode) && n@coarsen == 1L) {
    src_id <- n@parents[[1L]]
    resampling <- n@resampling
    bands <- n@bands
  } else if (S7::S7_inherits(n, SourceNode)) {
    src_id <- x@node_id
    resampling <- n@resampling
    bands <- integer(0)
  }
  src <- if (!is.null(src_id)) graph_get(x@graph, src_id)
  if (
    is.null(src) || !S7::S7_inherits(src, SourceNode) || length(src@collapsed)
  ) {
    cli::cli_abort(c(
      "{.fn coarsen} averages a read: apply it to a band of {.fn lazy_dataset} or {.fn lazy_source}.",
      "i" = "Coarsening computed rasters is not supported yet."
    ))
  }
  if (length(src@open_options)) {
    cli::cli_abort(c(
      "{.fn coarsen} reads plain sources; this one is opened with open options (a GTI slice, say).",
      "i" = "Coarsening option-driven sources is not supported yet."
    ))
  }
  if (!resampling %in% c("near", "nearest")) {
    cli::cli_abort(c(
      "{.fn coarsen} averages a nearest-neighbour read, not a {.val {resampling}} one.",
      "i" = "Read the sources with {.code resampling = \"near\"}."
    ))
  }
  g <- x@grid
  d <- g@dims
  if (any(d[c("x", "y")] %% k != 0L)) {
    cli::cli_abort(
      "{.arg x}'s grid ({d[['x']]} x {d[['y']]}) does not divide into {k} x {k} blocks."
    )
  }
  if (k == 1L) {
    return(x)
  }
  tt <- g@transform
  coarse <- GridSpec(
    crs = g@crs,
    transform = c(tt[[1L]], tt[[2L]] * k, 0, tt[[4L]], 0, tt[[6L]] * k),
    extent = g@extent,
    dims = c(
      x = d[["x"]] %/% k,
      y = d[["y"]] %/% k,
      d[setdiff(names(d), c("x", "y"))]
    ),
    dtype = "f32",
    labels = g@labels
  )
  id <- graph_add(
    x@graph,
    WarpNode,
    parents = src_id,
    grid = coarse,
    target_grid = coarse,
    resampling = "near",
    bands = bands,
    coarsen = k
  )
  LazyRaster(graph = x@graph, node_id = id, grid = coarse)
}

# print() cards and plan_draw() live in draw.R.
