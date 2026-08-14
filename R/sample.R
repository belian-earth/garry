#' @include lazy_raster.R dataset.R executor.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Point sampling: gather a lazy raster/dataset's values at points, without
# ever materialising the raster (design/sample-sink.md).
#
# A fit consumes a SAMPLE, not a cube. Extraction used to require a written
# raster, so pipelines staged whole cubes to disk purely to read values back
# at a few thousand points. A sample is a SINK, not a graph node: the plan
# runs as usual and the host tail gathers points instead of assembling a
# raster (.exec_sink_tail, shared by both executors).
#
# Geometry stays at the GDAL/PROJ boundary and is resolved at PLAN time:
# points reproject once on the host (gdalraster::transform_xy) and become
# cell indices. The engine only ever sees rows, columns and weights.
# ---------------------------------------------------------------------------

#' Sample a lazy raster or dataset at points.
#'
#' Executes the pipeline and returns the values at `pts` -- the table
#' equivalent of [collect()], and the way to feed a model fit without
#' staging the raster to disk first.
#'
#' Sampling is a sink, so everything upstream behaves exactly as it would
#' under [collect()]: reads stream through the daemon pools, kernels fuse
#' onto the reads, and only the gathered table reaches R.
#'
#' `method = "bilinear"` weights the four surrounding cell CENTRES by the
#' point's fractional position. Contributors that are nodata (`NaN`) or
#' outside the raster are dropped and the remaining weights are
#' RENORMALISED, so a point near a tile edge or a mask boundary still
#' yields a value; `NaN` comes back only when every contributor is
#' invalid. `method = "nearest"` (the default, matching
#' [lazy_dataset()]'s `resampling`) takes the containing cell exactly,
#' which is what packed QA bits and quantised codes need.
#'
#' @param x A `LazyRaster` or `LazyDataset`. A dataset is assembled along
#'   the band axis first (as [collect()] does), so its bands become the
#'   second dimension of the result.
#' @param pts A [wk::xy()] point vector carrying a CRS. Points in another
#'   CRS are reprojected onto the target grid; an unset CRS is an error
#'   rather than an assumption. Convert from sf, terra or a data frame
#'   with [wk::as_xy()].
#' @param method `"nearest"` (default) or `"bilinear"`; see above.
#' @param distributed Execute across the [garry_daemons()] pools? Defaults
#'   to [garry_daemons_set()], as in [collect()].
#' @return A numeric matrix shaped like [collect()]'s result without the
#'   spatial axes: one row per point, one column per layer of the sink's
#'   non-spatial axis (bands after a dataset is stacked, or time slices
#'   for a stacked cube), with that axis's labels as column names. Points
#'   outside the raster give an all-`NA` row, so the result always aligns
#'   row-for-row with `pts`.
#' @seealso [collect()], [write_tif()]
#' @export
sample_points <- function(
  x,
  pts,
  method = c("nearest", "bilinear"),
  distributed = garry_daemons_set()
) {
  method <- rlang::arg_match(method)
  if (S7::S7_inherits(x, LazyDatasetGroups)) {
    cli::cli_abort(c(
      "{.fn sample_points} does not take a grouped dataset.",
      "i" = "Sample each group, or {.fn reduce_over} the groups first."
    ))
  }
  if (S7::S7_inherits(x, LazyDataset)) {
    x <- stack_bands(x)
  }
  .assert_class(x, LazyRaster, "LazyRaster")
  xy <- .pts_xy(pts)
  .collect_impl(
    x,
    distributed = distributed,
    sample = list(xy = xy, method = method)
  )
}

# wk_xy -> list(x, y, crs, n). The CRS travels with the points, so there is
# no `crs` argument to get out of step with them; an unset CRS is an error
# rather than a silent assumption (garry never aligns implicitly).
.pts_xy <- function(pts) {
  if (!inherits(pts, "wk_xy")) {
    cli::cli_abort(c(
      "{.arg pts} must be a {.cls wk_xy} point vector.",
      "i" = "Convert sf/terra/data.frame points with {.fn wk::as_xy}."
    ))
  }
  crs <- wk::wk_crs(pts)
  if (is.null(crs) || inherits(crs, "wk_crs_inherit")) {
    cli::cli_abort(c(
      "{.arg pts} has no CRS.",
      "i" = "Set one with {.fn wk::wk_set_crs} so the points can be placed on the grid."
    ))
  }
  f <- unclass(pts)
  list(
    x = as.numeric(f$x),
    y = as.numeric(f$y),
    crs = wk::wk_crs_proj_definition(crs),
    n = length(f$x)
  )
}

# Contributor table for the gather: one row per (point, cell, weight).
#
# nearest  -> one row per point, the containing cell, weight 1.
# bilinear -> up to four rows, the surrounding cell CENTRES weighted by the
#             point's fractional position.
#
# Cells outside the raster are dropped here; the gather renormalises over
# whatever survives, which is what makes edge points usable. Grids are
# validated north-up and unrotated (GridSpec), so the pixel arithmetic is
# a plain affine inverse -- no adapter round-trip needed.
.sample_weights <- function(xy, grid, method) {
  gt <- grid@transform
  nx <- unname(grid@dims[["x"]])
  ny <- unname(grid@dims[["y"]])
  px <- xy$x
  py <- xy$y
  # Reproject once, on the host, at plan time. transform_* is the one
  # gdalraster family allowed outside the adapter (D13).
  if (!crs_equal(xy$crs, grid@crs)) {
    tp <- gdalraster::transform_xy(cbind(px, py), xy$crs, grid@crs)
    px <- tp[, 1L]
    py <- tp[, 2L]
  }
  fx <- (px - gt[[1L]]) / gt[[2L]]
  fy <- (py - gt[[4L]]) / gt[[6L]]
  if (identical(method, "nearest")) {
    w <- data.frame(
      pt = seq_along(px),
      row = floor(fy),
      col = floor(fx),
      wt = 1
    )
  } else {
    # Cell centres sit half a cell in from the edge, so the interpolation
    # frame is shifted by -0.5 before splitting into base cell + fraction.
    cx <- fx - 0.5
    cy <- fy - 0.5
    c0 <- floor(cx)
    r0 <- floor(cy)
    ax <- cx - c0
    ay <- cy - r0
    w <- data.frame(
      pt = rep(seq_along(px), 4L),
      row = c(r0, r0, r0 + 1, r0 + 1),
      col = c(c0, c0 + 1, c0, c0 + 1),
      wt = c((1 - ax) * (1 - ay), ax * (1 - ay), (1 - ax) * ay, ax * ay)
    )
  }
  w <- w[is.finite(w$row) & is.finite(w$col) & w$wt > 0, , drop = FALSE]
  w$row <- as.integer(w$row)
  w$col <- as.integer(w$col)
  w[w$row >= 0L & w$row < ny & w$col >= 0L & w$col < nx, , drop = FALSE]
}

# Gather the sampled values from a sink stage's chunks.
#
# Every contributor cell is looked up in whichever chunk owns it -- chunk
# indices are closed-form because the plan-wide tiling is index-aligned
# (chunk_iter orders ix fastest) -- so a point whose bilinear neighbourhood
# straddles a chunk boundary needs no halo: its four contributors are simply
# fetched from two or four different chunks.
#
# One pass over the chunks that hold contributors, accumulating a weighted
# sum and the weight that was actually VALID; dividing at the end gives the
# renormalisation. Values are written at the original point index, so the
# result order is independent of chunk completion order.
.sample_gather <- function(chunks, it, w, sink_pad, n_pts, outer_n, labels) {
  # Interior chunks carry the full tiling; edge chunks are clipped, never
  # padded, so the maxima recover the plan-wide chunk_dim.
  cx <- max(it$x_size)
  cy <- max(it$y_size)
  n_ix <- length(unique(it$ix))
  nb <- max(1L, outer_n)
  num <- matrix(0, nrow = n_pts, ncol = nb)
  den <- matrix(0, nrow = n_pts, ncol = nb)

  if (nrow(w) > 0L) {
    j <- (w$col %/% cx) + 1L + (w$row %/% cy) * n_ix
    for (jj in sort(unique(j))) {
      if (jj < 1L || jj > nrow(it) || is.null(chunks[[jj]])) {
        next
      }
      rows <- which(j == jj)
      v <- .exec_trim(.sv_materialise(chunks[[jj]]), sink_pad)
      d <- dim(v)
      cell <- cbind(w$row[rows] - it$y_off[[jj]] + 1L,
                    w$col[rows] - it$x_off[[jj]] + 1L)
      wt <- w$wt[rows]
      pt <- w$pt[rows]
      for (b in seq_len(nb)) {
        # store values are band-first (outer, y, x); a 2D chunk is one layer
        vals <- if (length(d) == 3L) v[b, , ][cell] else v[cell]
        ok <- is.finite(vals)
        if (!any(ok)) {
          next
        }
        # several contributors of one point can land in one chunk, so
        # accumulate by point rather than assign
        agg <- rowsum(cbind(wt[ok] * vals[ok], wt[ok]), pt[ok])
        idx <- as.integer(rownames(agg))
        num[idx, b] <- num[idx, b] + agg[, 1L]
        den[idx, b] <- den[idx, b] + agg[, 2L]
      }
    }
  }
  out <- ifelse(den > 0, num / den, NA_real_)
  dim(out) <- c(n_pts, nb)
  if (!is.null(labels) && length(labels) == nb) {
    dimnames(out) <- list(NULL, labels)
  }
  out
}
