# Kalman local-linear-trend smoother body for [`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md).

Returns a scan body `fn(xs, margin)` computing the smoothed level mean
(or its standard error) of a per-pixel local-linear-trend Kalman filter
with a Rauch-Tung-Striebel smoothing pass over the `t` axis, batched
over the chunk's pixels. This is the low-level building block; most
users want
[`kalman_smooth()`](https://belian-earth.github.io/garry/reference/kalman_smooth.md),
which wraps it. Use with
`scan_over(x, kalman_llt(...), direction = "bidir")`; `x` is the
observation stack, optionally `list(x, r)` with `r` a per-year relative
observation-variance stack (`Var(v_t) = sigma_obs^2 * r_t`; `r` must be
finite wherever `y` is observed).

## Usage

``` r
kalman_llt(
  sigma_lvl,
  sigma_slp,
  sigma_obs = 1,
  output = c("mean", "sd", "fmean", "fsd", "innov"),
  robust_iters = 0L,
  robust_threshold = 3,
  robust_inflation = 100,
  kappa = 1e+07,
  dtype = "f32"
)
```

## Arguments

- sigma_lvl, sigma_slp, sigma_obs:

  Noise standard deviations (level disturbance, slope disturbance,
  observation).

- output:

  `"mean"` (smoothed level), `"sd"` (its standard error), `"fmean"` (the
  forward-filtered level: each year from that year and earlier ones
  only), `"fsd"` (its standard error) or `"innov"` (the standardised
  innovation `(y - prediction) / sqrt(F)` of each observed year, 0 where
  missing: the filter's surprise, which a caller tests for persistent
  change).

- robust_iters:

  Robust reweighting passes (0 = plain smoother). Each pass inflates the
  level noise at years whose smoothed-level innovation exceeds
  `robust_threshold` MADs by `robust_inflation`.

- robust_threshold, robust_inflation:

  Robust loop constants.

- kappa:

  Diffuse-initialisation variance.

- dtype:

  Output dtype the body casts to (align with `scan_over(dtype = )`;
  default `"f32"`).

## Value

A scan body `fn(xs, margin)` for
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md).

## Details

Hyperparameters are fixed scalars, fitted outside the raster pipeline
(for example by marginal-likelihood MLE on sampled pixel series). Pixels
with fewer than 3 valid observations return all-NaN. Initialisation is
the large-variance diffuse approximation `P1 = kappa * I`.

## Regime boundaries

A third element of `xs`, a `(t, y, x)` stack of 0/1, marks years that
start a new regime. At a marked year the forward pass resets the state
covariance to the diffuse start (the level and slope are re-learned from
that year on), and the backward pass is blocked across it, so the
smoothed level before the boundary uses no observation from it or after.
Without boundaries the two-sided smoother carries change the model
cannot represent (a planting, a clearance) into the years before it;
with them, nothing crosses a boundary in either direction. A regime with
no observation is `NaN` (the forward outputs are `NaN` until a regime's
first observation). Boundaries are found by the caller, typically from
`"innov"`.

## See also

[`kalman_smooth()`](https://belian-earth.github.io/garry/reference/kalman_smooth.md),
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md),
[`g_scan()`](https://belian-earth.github.io/garry/reference/g_scan.md)
