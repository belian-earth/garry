# ---------------------------------------------------------------------------
# ChunkGrid: partitions a GridSpec into executable chunks.
#
# Wraps vaster's pixel-index primitives. Produces chunk enumerations and
# halo-padded windows. 2D now; time/band treated as outer dims by callers.
#
# Conventions (internal): 0-based pixel offsets on input to gdalraster;
# 1-based indexing stays inside R-facing utilities. Translation lives here
# and in the gdalraster adapter only.
# ---------------------------------------------------------------------------

#' A chunk partition of a GridSpec.
#'
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
#' @export
snap_to_blocks <- function(chunk_dim, block_dim) {
  as.integer(pmax(block_dim, ceiling(chunk_dim / block_dim) * block_dim))
}

#' Enumerate chunks.
#'
#' Returns a data frame of (ix, iy, x_off, y_off, x_size, y_size) for every
#' chunk. Offsets are 0-based. Sizes are clipped at the grid edge.
#'
#' @export
chunk_iter <- S7::new_generic("chunk_iter", "cg")

S7::method(chunk_iter, ChunkGrid) <- function(cg) {
  nx <- cg@grid@dim[1L]
  ny <- cg@grid@dim[2L]
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
  grid
}

#' Expand a chunk window by the ChunkGrid's halo, clipped to the grid.
#'
#' Returns a list with the padded window (`x_off`, `y_off`, `x_size`,
#' `y_size`) and the per-side pad actually applied (`pad_left`, `pad_top`,
#' `pad_right`, `pad_bottom`). Kernels trim by these values to recover the
#' unpadded output.
#'
#' @export
chunk_window_with_halo <- S7::new_generic("chunk_window_with_halo", "cg")

S7::method(chunk_window_with_halo, ChunkGrid) <- function(cg,
                                                          x_off, y_off,
                                                          x_size, y_size) {
  h  <- cg@halo
  nx <- cg@grid@dim[1L]
  ny <- cg@grid@dim[2L]

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

#' Map an output-chunk window on `out_grid` back to the minimal input window
#' required on `in_grid`. Used by WarpNode during planning.
#'
#' Pure geometry: takes two GridSpecs whose transforms may differ, plus an
#' output window in cells on `out_grid`, and returns the input window in
#' cells on `in_grid`.
#'
#' @export
cross_grid_window <- function(out_grid, in_grid,
                              x_off, y_off, x_size, y_size) {
  # Corners of the output window in world coords via out_grid's transform.
  corners_px_x <- c(x_off, x_off + x_size)
  corners_px_y <- c(y_off, y_off + y_size)

  gt_out <- out_grid@transform
  world_x <- gt_out[1L] + corners_px_x * gt_out[2L] + corners_px_y * gt_out[3L]
  world_y <- gt_out[4L] + corners_px_x * gt_out[5L] + corners_px_y * gt_out[6L]

  # Inverse of in_grid's transform, applied to the world corners.
  gt_in <- in_grid@transform
  det   <- gt_in[2L] * gt_in[6L] - gt_in[3L] * gt_in[5L]
  if (abs(det) < 1e-12) stop("input grid transform is singular")
  inv_a <-  gt_in[6L] / det
  inv_b <- -gt_in[3L] / det
  inv_d <- -gt_in[5L] / det
  inv_e <-  gt_in[2L] / det

  dx <- world_x - gt_in[1L]
  dy <- world_y - gt_in[4L]
  in_px_x <- dx * inv_a + dy * inv_b
  in_px_y <- dx * inv_d + dy * inv_e

  ix_lo <- floor(min(in_px_x))
  iy_lo <- floor(min(in_px_y))
  ix_hi <- ceiling(max(in_px_x))
  iy_hi <- ceiling(max(in_px_y))

  nx <- in_grid@dim[1L]
  ny <- in_grid@dim[2L]

  list(
    x_off  = as.integer(max(0L, ix_lo)),
    y_off  = as.integer(max(0L, iy_lo)),
    x_size = as.integer(min(nx, ix_hi) - max(0L, ix_lo)),
    y_size = as.integer(min(ny, iy_hi) - max(0L, iy_lo))
  )
}
