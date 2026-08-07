# Kalman local-linear-trend smoother body for [`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md).

Returns a scan body `fn(xs, margin)` computing the smoothed level mean
(or its standard error) of a per-pixel local-linear-trend Kalman
filter + RTS smoother over the `t` axis, batched over the chunk's
pixels. Use with `scan_over(x, kalman_llt(...), direction = "bidir")`;
`x` is the observation stack, optionally `list(x, r)` with `r` a
per-year relative observation-variance stack
(`Var(v_t) = sigma_obs^2 * r_t`; `r` must be finite wherever `y` is
observed).

## Usage

``` r
kalman_llt(
  sigma_lvl,
  sigma_slp,
  sigma_obs = 1,
  output = c("mean", "sd"),
  robust_iters = 0L,
  robust_threshold = 3,
  robust_inflation = 100,
  kappa = 1e+07,
  out_dtype = "f32"
)
```

## Arguments

- sigma_lvl, sigma_slp, sigma_obs:

  Noise standard deviations (level disturbance, slope disturbance,
  observation).

- output:

  `"mean"` (smoothed level) or `"sd"` (its standard error).

- robust_iters:

  Robust reweighting passes (0 = plain smoother). Each pass inflates the
  level noise at years whose smoothed-level innovation exceeds
  `robust_threshold` MADs by `robust_inflation`.

- robust_threshold, robust_inflation:

  Robust loop constants.

- kappa:

  Diffuse-initialisation variance.

- out_dtype:

  Output dtype the body casts to (align with `scan_over(dtype = )`;
  default `"f32"`).

## Value

A scan body `fn(xs, margin)` for
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md).

## Details

Hyperparameters are fixed R scalars, fitted off-raster (e.g. hutan's
marginal-likelihood MLE) and closed over as f64 constants. Pixels with
fewer than 3 valid observations return all-NaN (matching hutan).
Initialisation is the large-variance diffuse approximation
`P1 = kappa * I`; see the file header for the f64/kappa rationale.

`output = "mean"` and `output = "sd"` are separate scan bodies (one
export per node); the smoother recomputes per node, which is noise at T
~ 15 next to IO.

## See also

[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md),
[`g_scan()`](https://belian-earth.github.io/garry/reference/g_scan.md)
