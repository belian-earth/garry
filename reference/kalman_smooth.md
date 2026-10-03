# Smooth a stack with a local-linear-trend Kalman smoother.

Fits a per-pixel local-linear-trend Kalman filter and smoother over the
time axis and returns the smoothed level (and optionally its standard
error). Convenience wrapper: one
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md)
per requested output, sharing one
[`kalman_llt()`](https://belian-earth.github.io/garry/reference/kalman_llt.md)
parameterisation.

## Usage

``` r
kalman_smooth(
  x,
  sigma_lvl,
  sigma_slp,
  sigma_obs = 1,
  obs_var = NULL,
  boundaries = NULL,
  outputs = c("mean", "sd"),
  dtype = "f32",
  bands = NULL,
  ...
)
```

## Arguments

- x:

  Observation stack (`LazyRaster` with a `t` axis), or a `LazyDataset`
  (each band smoothed independently).

- sigma_lvl, sigma_slp, sigma_obs:

  Noise standard deviations (level disturbance, slope disturbance,
  observation).

- obs_var:

  Optional relative observation-variance stack on the same grid
  (`Var(v_t) = sigma_obs^2 * obs_var_t`).

- boundaries:

  Optional 0/1 stack on the same grid marking years that start a new
  regime (see
  [`kalman_llt()`](https://belian-earth.github.io/garry/reference/kalman_llt.md),
  section "Regime boundaries"); needs `obs_var` (pass a stack of ones
  for none).

- outputs:

  Which outputs to build (`"mean"`, `"sd"`, the forward-filtered
  `"fmean"`, `"fsd"`, and `"innov"`; see
  [`kalman_llt()`](https://belian-earth.github.io/garry/reference/kalman_llt.md)).

- dtype:

  Output dtype (default f32).

- bands:

  `LazyDataset` only: bands to smooth (default: all value bands). A
  dataset takes no `obs_var` or `boundaries`.

- ...:

  Passed to
  [`kalman_llt()`](https://belian-earth.github.io/garry/reference/kalman_llt.md).

## Value

A named list of lazy objects, one per requested output.

## See also

[`hampel_smooth()`](https://belian-earth.github.io/garry/reference/hampel_smooth.md)
for outlier removal,
[`fill_gaps()`](https://belian-earth.github.io/garry/reference/fill_gaps.md)
for simple gap filling,
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md)
for custom scans.
