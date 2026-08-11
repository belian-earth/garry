# Geometric median reducer over time (multivariate).

Returns a custom reducer for
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
computing, per pixel, the band-vector minimising the sum of Euclidean
distances to the observed band-vectors: the geometric (L1, spatial)
median. Unlike a per-band median, whose result can be a spectrum no real
observation ever had, the geometric median is a genuine multivariate
central tendency: every distance couples all bands.

## Usage

``` r
geomedian(iters = 12L, eps = 1e-07)
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

Solved by Weiszfeld iteration (a fixed-point weighted mean, weights
inverse distance to the current estimate), unrolled to a fixed `iters`
steps so it compiles to a static kernel. Timesteps with any NaN band are
ignored; pixels with no valid timestep return NaN.

The input must be a `(band, t, y, x)` cube: stack each band's
`(t, y, x)` stack along `"band"`, then reduce over `"t"`; the band axis
survives.

## See also

[`medoid()`](https://belian-earth.github.io/garry/reference/medoid.md),
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md);
[`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)
and
[`mlp_project()`](https://belian-earth.github.io/garry/reference/mlp_project.md)
for projections over the surviving band axis.
