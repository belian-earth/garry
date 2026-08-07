# A bilateral (edge-preserving) focal body for [`focal()`](https://belian-earth.github.io/garry/reference/focal.md).

Returns a focal `fn(shifts)` computing the classic bilateral filter:
each output pixel is the window mean weighted by a spatial Gaussian
(distance from the centre, `sigma_d`) times a range Gaussian (difference
from the centre VALUE, `sigma_r`), so smoothing stays within regions of
similar value and stops at sharp transitions. Use as
`focal(x, fn = bilateral_focal(sigma_r), radius = 1L)`.

## Usage

``` r
bilateral_focal(sigma_r, sigma_d = 1, radius = 1L)
```

## Arguments

- sigma_r:

  Range Gaussian standard deviation (data units).

- sigma_d:

  Spatial Gaussian standard deviation in pixels (default 1, hutan's
  `(window - 1) / 2` for a 3x3 window).

- radius:

  Window radius the body is built for; must match the `radius` passed to
  [`focal()`](https://belian-earth.github.io/garry/reference/focal.md)
  (default 1 = 3x3).

## Value

A focal body `fn(shifts)` for
[`focal()`](https://belian-earth.github.io/garry/reference/focal.md).

## Details

Semantics match
`rustyfilters::rf_bilateral(edge = "shrink", na_policy = "omit")`: a NaN
centre stays NaN; NaN neighbours (and the NaN halo garry pads outside
the raster) drop out of the weighted mean. `sigma_r` must be supplied:
the parameter-free per-band default (the band's own sd) is a
whole-raster statistic, so compute it in a separate reduce pass (or
reuse fitted values) and pass it in.
