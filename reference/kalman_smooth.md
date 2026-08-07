# Smooth a stack with the LLT Kalman smoother (mean + sd pair).

Convenience wrapper: one
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
  outputs = c("mean", "sd"),
  dtype = "f32",
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

- outputs:

  Which outputs to build (`"mean"`, `"sd"`).

- dtype:

  Output dtype (default f32).

- ...:

  Passed to
  [`kalman_llt()`](https://belian-earth.github.io/garry/reference/kalman_llt.md).

## Value

A named list of lazy objects, one per requested output.
