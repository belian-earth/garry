# ---------------------------------------------------------------------------
# Multivariate temporal reducers: geometric median and medoid
# (design/geometric-median-anvl.md, ir-extensions-todo.md #3).
#
# Both see the full band vector jointly: the input is a (band, t, y, x)
# cube (lazy_stack of per-band (t, y, x) stacks along "band"), the
# reduce axis is t, and the band axis survives. The multivariate
# coupling is nothing more than which axis each internal reduction
# runs over: distances are L2 norms over the BAND axis, updates are
# (weighted) means over the TIME axis. Batched over every pixel; no
# per-pixel loop; the Weiszfeld `for` unrolls at trace time into a
# fixed-depth DAG, so no new IR node is needed.
#
# NaN policy: a timestep is masked for a pixel when ANY band is NaN
# there (EO masks are cross-band); masked timesteps get zero weight and
# can never be selected. A pixel with no valid timestep returns NaN.
# ---------------------------------------------------------------------------

# Shared prelude: validate the cube, zero-fill NaN, per-timestep bad
# mask, and the Weiszfeld iteration. Returns everything the two
# reducers need.
.mb_weiszfeld <- function(x, dims, iters, eps) {
  td <- as.integer(dims)
  sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
  if (length(sh) != 4L || !identical(td, 2L))
    cli::cli_abort(c(
      "multivariate reducers need a (band, t, y, x) cube reduced over {.val t}.",
      "i" = paste("build it with {.code lazy_stack(per_band_stacks,",
                  "along = \"band\")} and {.code reduce_over(cube, fn,",
                  "over = \"t\")}")))
  B <- sh[[1L]]; T_ <- sh[[2L]]

  x0   <- g_ifelse(g_is_nodata(x), 0, x)               # NaN-free copy
  badt <- g_cast(g_is_nodata(g_sum(x, dims = 1L)), "f32")  # (t,y,x): any band NaN
  m    <- g_mean(x, dims = td, nan_rm = TRUE)          # init: per-band mean (B,y,x)
  for (k in seq_len(iters)) {
    mf <- g_expand(m, 2L, T_)                          # (band,t,y,x)
    d2 <- g_sum((x - mf) * (x - mf), dims = 1L)        # (t,y,x), NaN at masked t
    w  <- g_ifelse(badt > 0, 0, 1 / (sqrt(d2) + eps))  # (t,y,x)
    num <- g_sum(g_expand(w, 1L, B) * x0, dims = td)   # (B,y,x)
    den <- g_sum(w, dims = 1L)                         # (y,x)
    m <- num / g_expand(den, 1L, B)                    # all-masked: 0/0 = NaN
  }
  list(m = m, x0 = x0, badt = badt, B = B, T_ = T_, td = td)
}

#' Geometric median reducer over time (multivariate).
#'
#' Returns a custom reducer for [reduce_over()] computing, per pixel,
#' the band-vector minimising the sum of Euclidean distances to the
#' observed band-vectors: the geometric (L1, spatial) median. Unlike a
#' per-band median, whose result can be a spectrum no real observation
#' ever had, the geometric median is a genuine multivariate central
#' tendency: every distance couples all bands.
#'
#' Solved by Weiszfeld iteration (a fixed-point weighted mean,
#' weights inverse distance to the current estimate), unrolled to a
#' fixed `iters` steps so it compiles to a static kernel. Timesteps
#' with any NaN band are ignored; pixels with no valid timestep return
#' NaN.
#'
#' The input must be a `(band, t, y, x)` cube: stack each band's
#' `(t, y, x)` stack along `"band"`, then reduce over `"t"`; the band
#' axis survives.
#'
#' @param iters Weiszfeld iterations (fixed, unrolled).
#' @param eps Distance regulariser (guards the weight at zero distance).
#' @return A reducer `fn(x, dims)` for [reduce_over()].
#' @seealso [medoid()], [reduce_over()]; [band_project()] and
#'   [mlp_project()] for projections over the surviving band axis.
#' @export
geomedian <- function(iters = 12L, eps = 1e-7) {
  iters <- as.integer(iters)
  if (length(iters) != 1L || is.na(iters) || iters < 1L)
    cli::cli_abort("{.arg iters} must be a positive integer")
  if (!is.numeric(eps) || length(eps) != 1L || !is.finite(eps) || eps <= 0)
    cli::cli_abort("{.arg eps} must be a finite positive scalar")
  force(iters); force(eps)
  function(x, dims) .mb_weiszfeld(x, dims, iters, eps)$m
}

#' Medoid reducer over time (multivariate).
#'
#' Returns a custom reducer for [reduce_over()] computing, per pixel,
#' the *observed* band-vector nearest the [geomedian()]: a composite
#' whose every pixel is a real spectrum from a real date, following the
#' medoid construction of the Open Data Cube's hdstats package. Use it
#' when downstream analysis must not see synthetic spectra at all.
#'
#' Ties (several dates equally near) average; timesteps with any NaN
#' band are never selected; pixels with no valid timestep return NaN.
#' Input layout as [geomedian()]: a `(band, t, y, x)` cube reduced over
#' `"t"`.
#'
#' @inheritParams geomedian
#' @return A reducer `fn(x, dims)` for [reduce_over()].
#' @seealso [geomedian()], [reduce_over()]; [band_project()] and
#'   [mlp_project()] for projections over the surviving band axis.
#' @export
medoid <- function(iters = 12L, eps = 1e-7) {
  iters <- as.integer(iters)
  if (length(iters) != 1L || is.na(iters) || iters < 1L)
    cli::cli_abort("{.arg iters} must be a positive integer")
  if (!is.numeric(eps) || length(eps) != 1L || !is.finite(eps) || eps <= 0)
    cli::cli_abort("{.arg eps} must be a finite positive scalar")
  force(iters); force(eps)
  function(x, dims) {
    p <- .mb_weiszfeld(x, dims, iters, eps)
    mf <- g_expand(p$m, 2L, p$T_)                       # (band,t,y,x)
    d2 <- g_sum((x - mf) * (x - mf), dims = 1L)         # (t,y,x)
    d  <- g_ifelse(p$badt > 0, Inf, sqrt(d2))           # masked never wins
    dmin <- g_min(d, dims = 1L)                         # (y,x)
    sel  <- g_cast(d <= g_expand(dmin, 1L, p$T_), "f32")
    cnt  <- g_sum(sel, dims = 1L)                       # (y,x), ties > 1
    res  <- g_sum(g_expand(sel, 1L, p$B) * p$x0, dims = p$td) /
      g_expand(cnt, 1L, p$B)
    nv <- g_sum(1 - p$badt, dims = 1L)                  # (y,x) valid count
    g_ifelse(g_expand(nv, 1L, p$B) > 0, res, NaN)
  }
}
