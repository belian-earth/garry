# Reduction over named dims.

`op` is a reduction name, not a function: the planner needs op identity
for algebraic decomposition and dtype rules. `nan_rm = TRUE` (the
default) skips nodata, matching R's `na.rm = TRUE` under the NaN nodata
sentinel.

## Usage

``` r
reduce_over(x, op, over, nan_rm = TRUE, bands = NULL)
```

## Arguments

- x:

  A `LazyRaster`, or a `LazyDataset`.

- op:

  Reduction name: one of `"sum"`, `"mean"`, `"min"`, `"max"`,
  `"median"`, `"count"`. Alternatively a custom reducer: a function
  `fn(x, dims)` written in the `g_*` vocabulary that collapses the
  margins `dims` (e.g. a per-pixel model fit over time).

- over:

  Names of dims to reduce over (subset of `names(dims)`).

- nan_rm:

  Skip NaN (nodata) values?

- bands:

  `LazyDataset` only: bands to reduce (default: all bands).

## Value

A `LazyRaster` on the reduced grid, or a `LazyDataset` when given one.

## Details

Over a `LazyDataset`, each band is reduced independently (over `"t"`:
stack the band's slices and collapse time to a composite); `bands`
restricts which bands. `over = "band"` collapses the band axis,
returning a `LazyRaster`.

## See also

[`geomedian()`](https://belian-earth.github.io/garry/reference/geomedian.md)
and
[`medoid()`](https://belian-earth.github.io/garry/reference/medoid.md)
for multivariate time composites;
[`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)
and
[`mlp_project()`](https://belian-earth.github.io/garry/reference/mlp_project.md)
for band-axis models;
[`group_by_time()`](https://belian-earth.github.io/garry/reference/group_by_time.md)
for calendar-grouped reduction;
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md)
for order-preserving passes.

## Examples

``` r
f <- system.file("extdata", "garry-example.tif", package = "garry")
red <- lazy_source(f, band = 1L)
collect(reduce_over(red, "mean", c("x", "y")))
#> Error in confirm_plugin_install(platform, url): The "cpu" PJRT plugin needs to be downloaded for pjrt to work.
#> ℹ Automatic downloads are not performed in non-interactive sessions.
#> ℹ Set `PJRT_INSTALL` to "1" to allow the download, or set
#>   `PJRT_PLUGIN_PATH_CPU` to a local plugin file.
stk <- lazy_stack(list(a = red, b = red * 2))
dim(collect(reduce_over(stk, "median", "t")))
#> Error in confirm_plugin_install(platform, url): The "cpu" PJRT plugin needs to be downloaded for pjrt to work.
#> ℹ Automatic downloads are not performed in non-interactive sessions.
#> ℹ Set `PJRT_INSTALL` to "1" to allow the download, or set
#>   `PJRT_PLUGIN_PATH_CPU` to a local plugin file.
```
