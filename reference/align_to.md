# Lazily resample/reproject onto a target grid.

Inserts an explicit warp step, executed as a GDAL VRT warp. Alignment
stays explicit: binary ops never auto-resample.

## Usage

``` r
align_to(x, to, resampling = "near")
```

## Arguments

- x:

  A `LazyRaster`.

- to:

  Target grid: a `GridSpec` or another `LazyRaster`.

- resampling:

  GDAL resampling method. The default, `"near"`, copies source values
  unchanged, which categorical data (land cover, classes) and QA
  bitmasks need: interpolating them invents classes and bit patterns
  that do not exist. It matches the default of
  [`lazy_source()`](https://belian-earth.github.io/garry/reference/lazy_source.md)
  and
  [`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md).
  For continuous data (reflectance, elevation, temperature) choose
  `"bilinear"` (or `"cubic"`) when resampling to a similar or finer
  resolution, and `"average"` when aggregating to a coarser one.

## Value

A `LazyRaster` on the target grid.

## Details

Paste fast path: when `x` is already exactly on the target grid (same
CRS, transform, extent and dims;
[`grid_equal()`](https://belian-earth.github.io/garry/reference/grid_equal.md)),
`align_to()` is a no-op returning `x`: reads stay plain windowed reads,
with no warp barrier splitting the plan. This is the single-CRS-zone
workflow: pin the analysis grid to the sources' native grid and nothing
warps. Only EXACT equality pastes (unlike odc-stac's tolerance-based
`ttol`): a sub-pixel-shifted paste would silently move every pixel by up
to half a cell, so near-misses warp.

## Examples

``` r
f <- system.file("extdata", "garry-example.tif", package = "garry")
red <- lazy_source(f, band = 1L)
coarse <- grid_spec(crs = grid_crs(red), extent = grid_bbox(red), dims = c(30L, 20L))
dim(collect(align_to(red, coarse, resampling = "average")))
#> [1] 20 30
```
