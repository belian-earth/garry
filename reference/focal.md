# Focal (stencil) op.

`fn` receives a LIST of (2r+1)^2 shifted arrays, row-major over (dy, dx)
offsets, and returns one array: the whole neighbourhood is processed
vectorised across every pixel at once. Write `fn` with plain arithmetic
and the `g_*` vocabulary
([`g_ifelse()`](https://belian-earth.github.io/garry/reference/g_ifelse.md),
[`g_cast()`](https://belian-earth.github.io/garry/reference/g_cast.md),
...). Example, a 3x3 sum: `function(sh) Reduce("+", sh)`.

## Usage

``` r
focal(x, fn, radius, boundary = "nodata", bands = NULL)
```

## Arguments

- x:

  LazyRaster, or a `LazyDataset`.

- fn:

  Function over the list of shifted arrays (see above).

- radius:

  Halo in pixels (mandatory: the footprint cannot be inferred from
  `fn`).

- boundary:

  Boundary policy; only "nodata" in v1.

- bands:

  `LazyDataset` only: bands to apply to (default: all value bands).

## Value

A `LazyRaster` on the same grid as `x`, or a `LazyDataset` when given
one.

## Details

Cells beyond the raster edge are NaN (nodata): v1 supports only this
`boundary = "nodata"` policy; reflect/wrap are not implemented.

Over a `LazyDataset`, the stencil is applied to every value band per
slice; `bands` restricts which bands.

## See also

[`focal_kernel()`](https://belian-earth.github.io/garry/reference/focal_kernel.md),
[`bilateral_focal()`](https://belian-earth.github.io/garry/reference/bilateral_focal.md),
[`shrink_footprint()`](https://belian-earth.github.io/garry/reference/shrink_footprint.md)
