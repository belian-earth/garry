# Medoid reducer over time (multivariate).

Returns a custom reducer for
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
computing, per pixel, the *observed* band-vector nearest the
[`geomedian()`](https://belian-earth.github.io/garry/reference/geomedian.md):
a composite whose every pixel is a real spectrum from a real date (the
odc/hdstats medoid construction). Use it when downstream analysis must
not see synthetic spectra at all.

## Usage

``` r
medoid(iters = 12L, eps = 1e-07)
```

## Arguments

- iters:

  Weiszfeld iterations (fixed, unrolled).

- eps:

  Distance regulariser (guards the weight at zero distance).

## Value

A reducer `fn(x, dims)` for
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md).

## Details

Ties (several dates equally near) average; timesteps with any NaN band
are never selected; pixels with no valid timestep return NaN. Input
layout as
[`geomedian()`](https://belian-earth.github.io/garry/reference/geomedian.md):
a `(band, t, y, x)` cube reduced over `"t"`.

## See also

[`geomedian()`](https://belian-earth.github.io/garry/reference/geomedian.md),
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
