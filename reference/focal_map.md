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
focal_map(x, fn, radius, boundary = "nodata", bands = NULL)
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
`boundary = "nodata"` policy; reflect/wrap are not implemented. An
integer raster is read as f32 for the stencil, so the edge can be NaN,
and the result is f32.

Over a `LazyDataset`, the stencil is applied to every value band per
slice; `bands` restricts which bands.

## See also

[`focal_kernel()`](https://belian-earth.github.io/garry/reference/focal_kernel.md),
[`bilateral_focal()`](https://belian-earth.github.io/garry/reference/bilateral_focal.md),
[`shrink_footprint()`](https://belian-earth.github.io/garry/reference/shrink_footprint.md)

## Examples

``` r
f <- system.file("extdata", "garry-example.tif", package = "garry")
red <- lazy_source(f, band = 1L)
# a 3 x 3 window mean; cells at the raster edge are NaN
sm <- focal_map(red, radius = 1L, fn = function(sh) Reduce(`+`, sh) / length(sh))
collect(sm)[1:3, 1:3]
#> Error in confirm_plugin_install(platform, url): The "cpu" PJRT plugin needs to be downloaded for pjrt to work.
#> ℹ Automatic downloads are not performed in non-interactive sessions.
#> ℹ Set `PJRT_INSTALL` to "1" to allow the download, or set
#>   `PJRT_PLUGIN_PATH_CPU` to a local plugin file.
```
