# ---------------------------------------------------------------------------
# Multivariate temporal reducers: geometric median and medoid
# (design/geometric-median-anvl.md, ir-extensions-todo.md #3).
#
# Both see the full band vector jointly: the input is a (band, t, y, x)
# cube (lazy_stack of per-band (t, y, x) stacks along "band"), the
# reduce axis is t, and the band axis survives.
#
# The solver is a scan over dates, one (y, x) plane per band, nested in a
# scan over iterations. Written as whole-cube reductions the same map cost
# 14x on one core: XLA hands each one to its YNN fusion, which materialises
# the expanded, differenced and squared cubes, and the result varied in the
# last bit with chunk shape. A scan is byte-stable across chunk layouts, and
# holds a quarter of the memory. Every operation runs over bands, within
# one pixel, so pixels stay independent.
#
# NaN policy: a timestep is masked for a pixel when ANY band is NaN
# there (EO masks are cross-band); masked timesteps get zero weight and
# can never be selected. A pixel with no valid timestep returns NaN.
# NaN is the mask here: no zero-filled copy and no separate mask cube.
# ---------------------------------------------------------------------------

# Distance regulariser: guards a Weiszfeld weight at zero distance.
.mb_eps <- 1e-7

# A multivariate reducer's input as one (t, y, x) cube per band.
.mb_bands <- function(x, dims) {
  sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
  if (length(sh) != 4L || !identical(as.integer(dims), 2L)) {
    cli::cli_abort(c(
      "multivariate reducers need a (band, t, y, x) cube reduced over {.val t}.",
      "i" = paste(
        "build it with {.code lazy_stack(per_band_stacks,",
        "along = \"band\")} and {.code reduce_over(cube, fn,",
        "over = \"t\")}"
      )
    ))
  }
  # the solver's sums and weights are float, and a scan's carry keeps its type
  if (.g_is_integer(x)) {
    x <- g_cast(x, "f32")
  }
  bands <- lapply(seq_len(sh[[1L]]), function(b) {
    if (.g_traced(x)) {
      .g_reshape_rm(.g_slice_axis(x, 1L, b, b), sh[-1L])
    } else {
      array(x[b, , , ], sh[-1L])
    }
  })
  stats::setNames(bands, paste0("b", seq_along(bands)))
}

# A zero plane shaped like one date of `bands`.
.mb_zero <- function(bands) {
  cube <- bands[[1L]]
  if (.g_traced(cube)) {
    g_fill(0, .g_shape(cube)[-1L], .g_dtype(cube))
  } else {
    array(0, dim(cube)[-1L])
  }
}

# Squared distance from one date's band planes to the estimate.
.mb_dist2 <- function(date, m) {
  Reduce(`+`, Map(function(v, c) (v - c) * (v - c), date, m))
}

# Add one date to each band's running sum, `w` times over.
.mb_accumulate <- function(sums, date, keep, w) {
  Map(function(a, v) a + g_ifelse(keep, w * v, 0), sums, date)
}

# The mean of each pixel's valid dates: the solver's start. The test reads
# 1 / total rather than the total: XLA sinks a cheap test into every loop that
# uses it, and each would add the bands up again, while a divide stays one plane.
.mb_start <- function(bands, zero) {
  body <- function(s, date) {
    keep <- !g_is_nodata(1 / Reduce(`+`, date))
    list(
      carry = list(sums = .mb_accumulate(s$sums, date, keep, 1), n = s$n + g_ifelse(keep, 1, 0)),
      out = NULL
    )
  }
  init <- list(sums = rep(list(zero), length(bands)), n = zero)
  s <- g_scan(init, body, bands)$carry
  lapply(s$sums, function(a) a / s$n)
}

# Weiszfeld's map: the mean of the dates, weighted by inverse distance to `m`.
# `w` is NaN at a masked date and the test reads it, for .mb_start()'s reason:
# testing the distance would recompute it in every band's loop. A pixel with no
# valid date divides 0 by 0.
.mb_map <- function(bands, m, zero) {
  body <- function(s, date) {
    w <- 1 / (sqrt(.mb_dist2(date, m)) + .mb_eps)
    keep <- !g_is_nodata(w)
    list(
      carry = list(sums = .mb_accumulate(s$sums, date, keep, w), den = s$den + g_ifelse(keep, w, 0)),
      out = NULL
    )
  }
  init <- list(sums = rep(list(zero), length(bands)), den = zero)
  s <- g_scan(init, body, bands)$carry
  lapply(s$sums, function(a) a / s$den)
}

# The solver both reducers share: `iters` maps from the mean. Returns the bands,
# their zero plane and the estimate, one (y, x) plane per band.
.mb_weiszfeld <- function(x, dims, iters) {
  bands <- .mb_bands(x, dims)
  zero <- .mb_zero(bands)
  m <- .g_iterate(.mb_start(bands, zero), function(m) .mb_map(bands, m, zero), iters)
  list(m = m, bands = bands, zero = zero)
}

# One-band strip cubes a joint strip of these reducers holds per band, for
# .gd_fit(): its input, the read that filled it, its masked copy, and a share of
# the mask's two and the scan's few planes.
.mb_joint_cubes <- 3.5

# The iteration count of a multivariate reducer.
.mb_iters <- function(iters) {
  iters <- as.integer(iters)
  if (length(iters) != 1L || is.na(iters) || iters < 1L) {
    cli::cli_abort("{.arg iters} must be a positive integer")
  }
  iters
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
#' weights inverse distance to the current estimate) for a fixed
#' `iters` steps, so it compiles to a static kernel. Timesteps with any
#' NaN band are ignored; pixels with no valid timestep return NaN.
#'
#' The input must be a `(band, t, y, x)` cube: stack each band's
#' `(t, y, x)` stack along `"band"`, then reduce over `"t"`; the band
#' axis survives.
#'
#' @param iters Weiszfeld iterations.
#' @return A reducer `fn(x, dims)` for [reduce_over()].
#' @seealso [medoid()], [reduce_over()]; [band_project()] and
#'   [mlp_project()] for projections over the surviving band axis.
#' @export
geomedian <- function(iters = 12L) {
  iters <- .mb_iters(iters)
  structure(
    function(x, dims) g_stack(unname(.mb_weiszfeld(x, dims, iters)$m)),
    joint_cubes = .mb_joint_cubes
  )
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
medoid <- function(iters = 12L) {
  iters <- .mb_iters(iters)
  reduce <- function(x, dims) {
    p <- .mb_weiszfeld(x, dims, iters)
    # Comparisons with NaN are false, so a masked date never wins.
    body <- function(s, date) {
      d <- sqrt(.mb_dist2(date, p$m))
      win <- d < s$best
      tie <- d == s$best
      list(
        carry = list(
          best = g_ifelse(win, d, s$best),
          sums = Map(function(a, v) g_ifelse(win, v, g_ifelse(tie, a + v, a)), s$sums, date),
          n = g_ifelse(win, 1, g_ifelse(tie, s$n + 1, s$n))
        ),
        out = NULL
      )
    }
    init <- list(best = p$zero + Inf, sums = rep(list(p$zero), length(p$bands)), n = p$zero)
    s <- g_scan(init, body, p$bands)$carry
    g_stack(unname(lapply(s$sums, function(a) a / s$n)))
  }
  structure(reduce, joint_cubes = .mb_joint_cubes)
}
