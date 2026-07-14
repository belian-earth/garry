#' @include grid.R lazy_raster.R dataset.R collect.R gdal_adapter.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# preview(): a quick, informative plot of a lazy object, a collected array, or
# a raster file. The render engine (.plot_array) is matrix-native -- it takes a
# [y, x] matrix or (y, x, band) array plus a GridSpec, and does value->colour,
# percentile stretch, NA-transparent, discrete-vs-continuous colouring, geo axes
# from the grid, and a legend. No GDAL dataset, no decimation, no metadata: the
# caller supplies the array at preview resolution (files/arrays are decimated
# on the way in; lazy objects are collected). Ports the *rendering* from
# vrtility's plot engine and drops its read/decimate/metadata half.
# ---------------------------------------------------------------------------

# -- value -> colour --------------------------------------------------------

.pv_range <- function(v, stretch) {
  valid <- v[is.finite(v)]
  if (!length(valid)) return(c(0, 1))
  if (is.null(stretch)) return(range(valid))
  unname(stats::quantile(valid, probs = stretch / 100, na.rm = TRUE,
                         names = FALSE))
}

.pv_normalize <- function(v, mm) {
  d <- mm[[2L]] - mm[[1L]]; if (d == 0) d <- 1
  out <- (v - mm[[1L]]) / d
  out[out < 0] <- 0; out[out > 1] <- 1
  out
}

# A [0,1] -> hex colour mapper; non-finite inputs map to NA (transparent).
.pv_ramp <- function(col) {
  cr <- grDevices::colorRamp(col)
  function(x) {
    out <- rep(NA_character_, length(x))
    ok <- is.finite(x)
    if (any(ok)) {
      m <- cr(x[ok])
      out[ok] <- grDevices::rgb(m[, 1L], m[, 2L], m[, 3L], maxColorValue = 255)
    }
    out
  }
}

# Fewer than `max_levels` distinct values -> treat as categorical.
.pv_discrete <- function(v, max_levels = 12L) {
  u <- unique(v[is.finite(v)])
  if (length(u) > 0L && length(u) < max_levels) sort(u) else NULL
}

# Build the colour raster + legend info for one band.
.pv_band_raster <- function(v, col, stretch) {
  disc <- .pv_discrete(v)
  if (!is.null(disc)) {
    pos <- if (length(disc) > 1L) seq(0, 1, length.out = length(disc)) else 0.5
    dcols <- .pv_ramp(col)(pos)
    cols <- dcols[match(v, disc)]                 # non-finite -> NA -> clear
    return(list(ras = grDevices::as.raster(matrix(cols, nrow(v), ncol(v))),
                disc = disc, dcols = dcols, mm = NULL))
  }
  mm <- .pv_range(v, stretch)
  cols <- .pv_ramp(col)(.pv_normalize(v, mm))
  list(ras = grDevices::as.raster(matrix(cols, nrow(v), ncol(v))),
       disc = NULL, dcols = NULL, mm = mm)
}

# Combine three bands into an RGB raster, per-channel percentile stretch.
.pv_rgb_raster <- function(arr, bands, stretch) {
  ch <- lapply(bands, function(b) {
    v <- arr[, , b]; .pv_normalize(v, .pv_range(v, stretch))
  })
  na <- Reduce(`|`, lapply(ch, function(c2) !is.finite(c2)))
  hex <- grDevices::rgb(ifelse(na, 0, ch[[1L]]), ifelse(na, 0, ch[[2L]]),
                        ifelse(na, 0, ch[[3L]]))
  hex[na] <- NA
  grDevices::as.raster(matrix(hex, nrow(arr), ncol(arr)))
}

# -- axes and legend --------------------------------------------------------

.pv_digits <- function(v) {
  v <- v[is.finite(v)]
  if (!length(v)) return(0L)
  if (all(v == round(v))) return(0L)
  mag <- max(abs(v))
  if (mag >= 100) 1L else if (diff(range(v)) >= 1) 2L else 3L
}

.pv_axes <- function(xlim, ylim, main, xlab, ylab) {
  xt <- pretty(xlim, 5); xt <- xt[xt >= xlim[[1L]] & xt <= xlim[[2L]]]
  yt <- pretty(ylim, 5); yt <- yt[yt >= ylim[[1L]] & yt <= ylim[[2L]]]
  graphics::axis(1, at = xt, pos = ylim[[1L]], lwd = 0, lwd.ticks = 1, cex.axis = 0.9)
  graphics::axis(2, at = yt, pos = xlim[[1L]], lwd = 0, lwd.ticks = 1, cex.axis = 0.9)
  graphics::rect(xlim[[1L]], ylim[[1L]], xlim[[2L]], ylim[[2L]], border = "black")
  if (nzchar(main)) graphics::mtext(main, side = 3, line = 0.5, font = 2,
                                    cex = 1.3, at = mean(xlim))
  if (nzchar(xlab)) graphics::mtext(xlab, side = 1, line = 2.5, at = mean(xlim))
  if (nzchar(ylab)) graphics::mtext(ylab, side = 2, line = 3)
}

.pv_legend <- function(built, col, xlim, ylim) {
  lx0 <- xlim[[2L]] + 0.03 * diff(xlim); lx1 <- xlim[[2L]] + 0.07 * diff(xlim)
  yr <- diff(ylim); ly0 <- ylim[[1L]] + 0.1 * yr; ly1 <- ylim[[2L]] - 0.1 * yr
  tx <- lx1 + 0.02 * diff(xlim)
  if (!is.null(built$disc)) {
    n <- length(built$disc)
    ys <- seq(ly0, ly1, length.out = n + 1L)
    for (i in seq_len(n))
      graphics::rect(lx0, ys[[i]], lx1, ys[[i + 1L]], col = built$dcols[[i]],
                     border = NA)
    graphics::rect(lx0, ly0, lx1, ly1, border = "black")
    labs <- formatC(built$disc, format = if (all(built$disc == round(built$disc)))
                    "d" else "f", digits = .pv_digits(built$disc))
    graphics::text(tx, (ys[-1L] + ys[-length(ys)]) / 2, labs, adj = c(0, 0.5),
                   cex = 0.85)
  } else {
    mm <- built$mm
    grad <- .pv_ramp(col)(seq(1, 0, length.out = 128L))   # top = high
    graphics::rasterImage(grDevices::as.raster(matrix(grad, ncol = 1L)),
                          lx0, ly0, lx1, ly1)
    graphics::rect(lx0, ly0, lx1, ly1, border = "black")
    labs <- formatC(seq(mm[[1L]], mm[[2L]], length.out = 5L), format = "f",
                    digits = .pv_digits(mm))
    graphics::text(tx, seq(ly0, ly1, length.out = 5L), labs, adj = c(0, 0.5),
                   cex = 0.85)
  }
}

# -- the render engine ------------------------------------------------------

# arr: a [y, x] matrix or (y, x, band) array (spatial-first, layer-last, as
# collect() returns). grid: optional GridSpec for the map extent/axes.
.plot_array <- function(arr, grid = NULL, bands = NULL, stretch = c(2, 98),
                        col = grDevices::hcl.colors(64, "Viridis"),
                        legend = NULL, main = "", axes = TRUE,
                        xlab = "", ylab = "", interpolate = TRUE) {
  nb_avail <- if (length(dim(arr)) == 3L) dim(arr)[[3L]] else 1L
  if (is.null(bands)) bands <- if (nb_avail >= 3L) 1:3 else 1L
  if (!length(bands) %in% c(1L, 3L))
    cli::cli_abort("{.arg bands} must select 1 or 3 bands.")
  band1 <- function() if (length(dim(arr)) == 3L) arr[, , bands[[1L]]] else arr

  ext <- if (!is.null(grid)) grid@extent else {
    d <- dim(arr); c(0, 0, d[[2L]], d[[1L]])
  }
  xlim <- ext[c(1L, 3L)]; ylim <- ext[c(2L, 4L)]

  if (length(bands) == 1L) {
    built <- .pv_band_raster(band1(), col, stretch)
  } else {
    built <- list(ras = .pv_rgb_raster(arr, bands, stretch), disc = NULL, mm = NULL)
  }
  if (is.null(legend)) legend <- length(bands) == 1L
  if (legend && length(bands) != 1L) legend <- FALSE

  op <- graphics::par(mar = c(if (nzchar(xlab)) 4 else 2.5,
                              if (nzchar(ylab)) 4 else 2.5,
                              if (nzchar(main)) 3 else 1.5, 1) + 0.1)
  on.exit(graphics::par(op), add = TRUE)
  graphics::plot.new()
  xr <- if (legend) c(xlim[[1L]], xlim[[1L]] + 1.16 * diff(xlim)) else xlim
  graphics::plot.window(xlim = xr, ylim = ylim, asp = 1, xaxs = "i", yaxs = "i")
  graphics::rasterImage(built$ras, xlim[[1L]], ylim[[1L]], xlim[[2L]], ylim[[2L]],
                        interpolate = interpolate)
  if (axes) .pv_axes(xlim, ylim, main, xlab, ylab)
  else if (nzchar(main))
    graphics::mtext(main, side = 3, line = 0.5, font = 2, cex = 1.3)
  if (legend) .pv_legend(built, col, xlim, ylim)
  invisible()
}

# -- front doors ------------------------------------------------------------

# Target longest-axis pixels: an explicit cap, else the device size.
.pv_target <- function(max_px = NULL) {
  if (!is.null(max_px)) return(as.integer(max_px))
  sz <- tryCatch(grDevices::dev.size("px"), error = function(e) c(720, 720))
  max(as.integer(sz))
}

# Nearest-neighbour subsample to <= target pixels on the long axis.
.pv_decimate <- function(arr, target) {
  d <- dim(arr); ny <- d[[1L]]; nx <- d[[2L]]
  k <- max(ny, nx) / target
  if (k <= 1) return(arr)
  yi <- unique(round(seq(1, ny, length.out = max(1L, floor(ny / k)))))
  xi <- unique(round(seq(1, nx, length.out = max(1L, floor(nx / k)))))
  if (length(d) == 3L) arr[yi, xi, , drop = FALSE] else arr[yi, xi, drop = FALSE]
}

# Read a raster file into a (decimated) array using garry's adapter (nodata ->
# NaN, [y, x] orientation), plus its grid for the axes.
.pv_read_path <- function(path, bands, target) {
  meta <- gdal_grid_spec(path)
  nx <- meta$grid@dims[["x"]]; ny <- meta$grid@dims[["y"]]
  nb <- gdal_band_count(path)
  b <- bands %||% (if (nb >= 3L) 1:3 else 1L)
  layers <- lapply(b, function(bi) gdal_read_window(path, bi, 0L, 0L, nx, ny))
  arr <- if (length(b) == 1L) layers[[1L]] else simplify2array(layers)
  list(arr = .pv_decimate(arr, target), grid = meta$grid, bands = seq_along(b))
}

#' Preview a lazy object, a collected array, or a raster file.
#'
#' A quick, informative plot: single band as a colour ramp with a legend, three
#' bands as a stretched RGB composite, categorical data (few distinct values)
#' with discrete colours. Nodata is transparent; a percentile `stretch` sets the
#' colour range; axes come from the grid.
#'
#' Inputs are reduced before rendering: a file or an array is decimated to the
#' device (or `max_px`); a `LazyDataset`/`LazyRaster` is `collect()`ed (a coarse
#' re-plan that fetches at preview resolution is the intended optimisation).
#'
#' @param x A `LazyRaster`, `LazyDataset`, a matrix/array from `collect()`, or a
#'   path to a raster file.
#' @param bands Bands to show: 1 for a colour ramp, 3 for RGB. For a
#'   `LazyDataset`, band names are also accepted. Defaults to the first 3 bands
#'   (RGB) or band 1.
#' @param max_px Longest-axis pixel budget for the render; defaults to the
#'   device size.
#' @param stretch Percentile cut `c(low, high)` for the colour range, or `NULL`
#'   for min/max.
#' @param col Colour ramp for single-band plots.
#' @param legend Draw a legend? Defaults to `TRUE` for single band, `FALSE` for
#'   RGB.
#' @param main,axes,xlab,ylab Plot title, axes toggle, and axis labels.
#' @param ... Unused.
#' @return `x`, invisibly.
#' @export
preview <- function(x, bands = NULL, max_px = NULL, stretch = c(2, 98),
                    col = grDevices::hcl.colors(64, "Viridis"),
                    legend = NULL, main = "", axes = TRUE, xlab = "", ylab = "",
                    ...) {
  target <- .pv_target(max_px)
  grid <- NULL
  if (S7::S7_inherits(x, LazyDataset)) {
    if (is.character(bands)) { x <- x[bands]; bands <- seq_along(bands) }
    grid <- .ds_grid(x)
    arr <- .pv_decimate(collect(x), target)
  } else if (S7::S7_inherits(x, LazyRaster)) {
    grid <- x@grid
    arr <- .pv_decimate(collect(x), target)
  } else if (is.character(x) && length(x) == 1L) {
    rd <- .pv_read_path(x, bands, target); arr <- rd$arr; grid <- rd$grid
    if (is.null(bands)) bands <- rd$bands
  } else if (is.array(x) || is.matrix(x)) {
    arr <- .pv_decimate(x, target)
  } else {
    cli::cli_abort(paste("{.fn preview} needs a LazyRaster/LazyDataset,",
                         "a matrix/array, or a file path."))
  }
  .plot_array(arr, grid = grid, bands = bands, stretch = stretch, col = col,
              legend = legend, main = main, axes = axes, xlab = xlab, ylab = ylab)
  invisible(x)
}
