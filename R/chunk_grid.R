#' @include grid.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# ChunkGrid: partitions a GridSpec into executable chunks.
#
# Produces chunk enumerations and halo-padded windows. 2D now; time/band
# treated as outer dims by callers.
#
# Conventions (internal): 0-based pixel offsets on input to gdalraster;
# 1-based indexing stays inside R-facing utilities. Translation lives here
# and in the gdalraster adapter only.
# ---------------------------------------------------------------------------

#' A chunk partition of a GridSpec.
#'
#' @param grid The `GridSpec` being partitioned.
#' @param chunk_dim Integer length 2: chunk size (cx, cy) in pixels.
#' @param block_dim Integer length 2: native GDAL block size, for snapping.
#' @param halo Single non-negative integer halo radius in pixels.
#' @return A `ChunkGrid`.
#' @export
ChunkGrid <- S7::new_class(
  "ChunkGrid",
  properties = list(
    grid      = GridSpec,
    chunk_dim = S7::class_integer,   # length 2: (cx, cy)
    block_dim = S7::class_integer,   # native GDAL block dim, for snapping
    halo      = S7::class_integer    # length 1, radius in pixels
  ),
  validator = function(self) {
    if (length(self@chunk_dim) != 2L || any(self@chunk_dim <= 0L))
      return("`chunk_dim` must be length 2 with positive values")
    if (length(self@block_dim) != 2L || any(self@block_dim <= 0L))
      return("`block_dim` must be length 2 with positive values")
    if (length(self@halo) != 1L || self@halo < 0L)
      return("`halo` must be a single non-negative integer")
    NULL
  }
)

#' Snap requested chunk size to a multiple of native block size.
#'
#' @param chunk_dim Requested chunk size, integer length 2.
#' @param block_dim Native block size, integer length 2.
#' @return Integer length 2, block-aligned and at least one block.
#' @export
snap_to_blocks <- function(chunk_dim, block_dim) {
  as.integer(pmax(block_dim, ceiling(chunk_dim / block_dim) * block_dim))
}

#' Enumerate chunks.
#'
#' Returns a data frame of (ix, iy, x_off, y_off, x_size, y_size, shape_id)
#' for every chunk. Offsets are 0-based. Sizes are clipped at the grid
#' edge. `shape_id` classifies each chunk as "interior", "right",
#' "bottom", or "corner" — a regular chunk grid produces at most these
#' four distinct shapes (decision D4: no pad-to-uniform; the executor's
#' kernel cache sees <= 4 shapes per stage).
#'
#' @param cg A `ChunkGrid`.
#' @param ... Passed to methods.
#' @return A data frame with one row per chunk.
#' @export
chunk_iter <- S7::new_generic("chunk_iter", "cg")

S7::method(chunk_iter, ChunkGrid) <- function(cg) {
  nx <- cg@grid@dims[1L]
  ny <- cg@grid@dims[2L]
  cx <- cg@chunk_dim[1L]
  cy <- cg@chunk_dim[2L]

  x_starts <- seq.int(0L, nx - 1L, by = cx)
  y_starts <- seq.int(0L, ny - 1L, by = cy)

  grid <- expand.grid(ix = seq_along(x_starts),
                      iy = seq_along(y_starts),
                      KEEP.OUT.ATTRS = FALSE,
                      stringsAsFactors = FALSE)
  grid$x_off  <- x_starts[grid$ix]
  grid$y_off  <- y_starts[grid$iy]
  grid$x_size <- pmin(cx, nx - grid$x_off)
  grid$y_size <- pmin(cy, ny - grid$y_off)

  # Compare against the effective chunk size so a single-column/row grid
  # (chunk larger than raster) counts as interior, not clipped.
  clipped_x <- grid$x_size < min(cx, nx)
  clipped_y <- grid$y_size < min(cy, ny)
  grid$shape_id <- ifelse(clipped_x & clipped_y, "corner",
                   ifelse(clipped_x, "right",
                   ifelse(clipped_y, "bottom", "interior")))
  grid
}

#' Expand a chunk window by the ChunkGrid's halo, clipped to the grid.
#'
#' Returns a list with the padded window (`x_off`, `y_off`, `x_size`,
#' `y_size`) and the per-side pad actually applied (`pad_left`, `pad_top`,
#' `pad_right`, `pad_bottom`). Kernels trim by these values to recover the
#' unpadded output.
#'
#' @param cg A `ChunkGrid`.
#' @param ... Method arguments: `x_off`, `y_off`, `x_size`, `y_size`, the
#'   0-based unpadded chunk window.
#' @return A list with the padded window and per-side pads.
#' @export
chunk_window_with_halo <- S7::new_generic("chunk_window_with_halo", "cg")

S7::method(chunk_window_with_halo, ChunkGrid) <- function(cg,
                                                          x_off, y_off,
                                                          x_size, y_size) {
  h  <- cg@halo
  nx <- cg@grid@dims[1L]
  ny <- cg@grid@dims[2L]

  x_lo <- max(0L, x_off - h)
  y_lo <- max(0L, y_off - h)
  x_hi <- min(nx, x_off + x_size + h)
  y_hi <- min(ny, y_off + y_size + h)

  list(
    x_off      = x_lo,
    y_off      = y_lo,
    x_size     = x_hi - x_lo,
    y_size     = y_hi - y_lo,
    pad_left   = x_off - x_lo,
    pad_top    = y_off - y_lo,
    pad_right  = x_hi - (x_off + x_size),
    pad_bottom = y_hi - (y_off + y_size)
  )
}

# ---------------------------------------------------------------------------
# Cross-grid window mapping.
#
# Decision D5: this is a PLANNING ESTIMATE only, and it must CONTAIN the
# true input window (over-estimates are safe, under-estimates are bugs).
# Execution-time window math for warps is owned by GDAL's warper (Phase
# 4b); nothing downstream may treat these windows as exact.
# ---------------------------------------------------------------------------

# World bounds (xmin, ymin, xmax, ymax) of a 0-based pixel window on a
# north-up grid.
.window_world_bounds <- function(grid, x_off, y_off, x_size, y_size) {
  gt <- grid@transform
  c(gt[1L] + x_off * gt[2L],
    gt[4L] + (y_off + y_size) * gt[6L],
    gt[1L] + (x_off + x_size) * gt[2L],
    gt[4L] + y_off * gt[6L])
}

#' Map an output-chunk window on `out_grid` to the minimal input window
#' required on `in_grid`.
#'
#' Same CRS: exact affine math (north-up grids, so window corners are
#' extremal). Different CRS: bounds are transformed with
#' `gdalraster::transform_bounds()`, which densifies the boundary so
#' curved edges (e.g. parallels in a transverse Mercator zone) cannot
#' shrink the window; a safety margin of `garry_opt("window_margin")`
#' input cells is then added.
#'
#' Returns a list (x_off, y_off, x_size, y_size), 0-based, clipped to
#' `in_grid`. A window fully outside `in_grid` returns zero sizes.
#'
#' @param out_grid,in_grid `GridSpec`s of the consumer and producer.
#' @param x_off,y_off,x_size,y_size 0-based output window on `out_grid`.
#' @param margin Safety margin in input cells; defaults to 0 for same-CRS
#'   windows and `garry_opt("window_margin")` across CRS.
#' @return A list with the 0-based input window.
#' @export
cross_grid_window <- function(out_grid, in_grid,
                              x_off, y_off, x_size, y_size,
                              margin = NULL) {
  bounds <- .window_world_bounds(out_grid, x_off, y_off, x_size, y_size)

  same_crs <- crs_equal(out_grid@crs, in_grid@crs)
  if (!same_crs) {
    bounds <- gdalraster::transform_bounds(bounds, out_grid@crs, in_grid@crs)
    if (is.null(margin)) margin <- garry_opt("window_margin")
  }
  if (is.null(margin)) margin <- 0L

  gt <- in_grid@transform
  # North-up: x from xmin/xmax, y rows from ymax downwards (gt[6] < 0).
  px_lo <- floor((bounds[1L] - gt[1L]) / gt[2L])
  px_hi <- ceiling((bounds[3L] - gt[1L]) / gt[2L])
  py_lo <- floor((bounds[4L] - gt[4L]) / gt[6L])
  py_hi <- ceiling((bounds[2L] - gt[4L]) / gt[6L])

  px_lo <- px_lo - margin; py_lo <- py_lo - margin
  px_hi <- px_hi + margin; py_hi <- py_hi + margin

  nx <- in_grid@dims[1L]
  ny <- in_grid@dims[2L]
  x_lo <- min(max(0, px_lo), nx)
  y_lo <- min(max(0, py_lo), ny)
  x_hi <- max(min(nx, px_hi), x_lo)
  y_hi <- max(min(ny, py_hi), y_lo)

  list(
    x_off  = as.integer(x_lo),
    y_off  = as.integer(y_lo),
    x_size = as.integer(x_hi - x_lo),
    y_size = as.integer(y_hi - y_lo)
  )
}
