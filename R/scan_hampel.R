# ---------------------------------------------------------------------------
# Hampel filter over the t axis: a centred rolling window's median/MAD
# knocks outliers down to the window median. Not recursive, so the body
# needs no g_scan(): it builds the 2k+1 t-shifted copies of the cube
# (NaN-padded at the series ends), stacks them along a new leading axis,
# and reduces that axis with nan_rm medians. Runs identically traced
# (anvl) and untraced (the pure-R oracle), like every scan body.
# ---------------------------------------------------------------------------

# fn(xs, margin) for scan_over(): xs[[1]] is the (t, y, x) observation
# cube; k window half-width; t0 the MAD threshold.
.hampel_body <- function(k, t0) {
  force(k); force(t0)
  function(xs, margin) {
    if (!identical(as.integer(margin), 1L))
      cli::cli_abort("hampel filter scans dim 1 (margin 1); got margin {margin}")
    y <- xs[[1L]]
    T_ <- if (.g_traced(y)) .g_shape(y)[[1L]] else dim(y)[[1L]]
    if (T_ < 2L)
      cli::cli_abort("hampel filter needs at least 2 time slices; got {T_}")
    kk <- min(k, T_ - 1L)
    shifts <- lapply(seq(-kk, kk), function(d) {
      if (d == 0L) return(y)
      dd <- abs(d)
      pad <- g_slice_t(y, 1L, dd) * NaN
      if (d > 0L) g_concat_t(list(g_slice_t(y, 1L + dd, T_), pad))
      else        g_concat_t(list(pad, g_slice_t(y, 1L, T_ - dd)))
    })
    S   <- g_stack(shifts)                      # (2k+1, t, y, x)
    med <- g_median(S, dims = 1L, nan_rm = TRUE)
    mad <- g_median(abs(S - g_rep_t(med, length(shifts))),
                    dims = 1L, nan_rm = TRUE) * 1.4826
    out <- g_ifelse(abs(y - med) <= t0 * mad, y, med)
    g_ifelse(g_is_nodata(y), NaN, out)          # gaps stay gaps
  }
}

#' Hampel filter a stack over its time axis.
#'
#' The classic despiking filter: for each time step, a centred window of
#' `k` steps either side supplies a median and a MAD (median absolute
#' deviation, scaled by 1.4826 to estimate a standard deviation); an
#' observation further than `t0` MADs from the window median is replaced
#' *by* that median. Missing steps (NaN) are skipped by the window
#' statistics and stay missing in the output: this filter removes
#' spikes, it does not fill gaps (compose with [fill_gaps()] or
#' [kalman_smooth()] for that).
#'
#' The window is positional (`k` slices, not calendar days), and shrinks
#' at the series ends. `t0 = 0` degenerates to a rolling median. With
#' `t0 > 0`, note the MAD of a window whose valid values are mostly
#' identical is 0, so any deviating centre is replaced; this is inherent
#' to the Hampel construction.
#'
#' Like every garry verb it is lazy (nothing computes until
#' [collect()]), and it applies per band over a `LazyDataset`.
#'
#' @param x A `(t, y, x)` `LazyRaster`, or a `LazyDataset` (each band
#'   filtered independently).
#' @param k Window half-width in time steps (window size `2k + 1`).
#' @param t0 Threshold in scaled MADs (default 3; 0 = rolling median).
#' @param bands `LazyDataset` only: bands to filter (default: all).
#' @return The filtered object, same class and grid as `x`.
#' @seealso [kalman_smooth()], [fill_gaps()], [scan_over()]
#' @export
hampel_smooth <- function(x, k = 3L, t0 = 3, bands = NULL) {
  k <- as.integer(k)
  if (length(k) != 1L || is.na(k) || k < 1L)
    cli::cli_abort("{.arg k} must be a positive integer")
  if (!is.numeric(t0) || length(t0) != 1L || !is.finite(t0) || t0 < 0)
    cli::cli_abort("{.arg t0} must be a finite non-negative scalar")
  scan_over(x, .hampel_body(k, t0), over = "t", direction = "bidir",
            bands = bands)
}
