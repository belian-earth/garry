# Hampel filter a stack over its time axis.

The classic despiking filter: for each time step, a centred window of
`k` steps either side supplies a median and a MAD (median absolute
deviation, scaled by 1.4826 to estimate a standard deviation); an
observation further than `t0` MADs from the window median is replaced
*by* that median. Missing steps (NaN) are skipped by the window
statistics and stay missing in the output: this filter removes spikes,
it does not fill gaps (compose with
[`fill_gaps()`](https://belian-earth.github.io/garry/reference/fill_gaps.md)
or
[`kalman_smooth()`](https://belian-earth.github.io/garry/reference/kalman_smooth.md)
for that).

## Usage

``` r
hampel_smooth(x, k = 3L, t0 = 3, bands = NULL)
```

## Arguments

- x:

  A `(t, y, x)` `LazyRaster`, or a `LazyDataset` (each band filtered
  independently).

- k:

  Window half-width in time steps (window size `2k + 1`).

- t0:

  Threshold in scaled MADs (default 3; 0 = rolling median).

- bands:

  `LazyDataset` only: bands to filter (default: all).

## Value

The filtered object, same class and grid as `x`.

## Details

The window is positional (`k` slices, not calendar days), and shrinks at
the series ends. `t0 = 0` degenerates to a rolling median. With
`t0 > 0`, note the MAD of a window whose valid values are mostly
identical is 0, so any deviating centre is replaced; this is inherent to
the Hampel construction.

Runs through
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md),
so it plans, fuses, and distributes like any other kernel, and applies
per band over a `LazyDataset`.

## See also

[`kalman_smooth()`](https://belian-earth.github.io/garry/reference/kalman_smooth.md),
[`fill_gaps()`](https://belian-earth.github.io/garry/reference/fill_gaps.md),
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md)
