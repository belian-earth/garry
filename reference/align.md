# Lazily resample/reproject onto a target grid.

Inserts an explicit warp step, executed as a GDAL VRT warp. Alignment
stays explicit: binary ops never auto-resample.

## Usage

``` r
align(x, to, resampling = "bilinear")
```

## Arguments

- x:

  A `LazyRaster`.

- to:

  Target grid: a `GridSpec` or another `LazyRaster`.

- resampling:

  GDAL resampling method.

## Value

A `LazyRaster` on the target grid.

## Details

Paste fast path: when `x` is already exactly on the target grid (same
CRS, transform, extent and dims;
[`grid_equal()`](https://belian-earth.github.io/garry/reference/grid_equal.md)),
`align()` is a no-op returning `x`: reads stay plain windowed reads,
with no warp barrier splitting the plan. This is the single-CRS-zone
workflow: pin the analysis grid to the sources' native grid and nothing
warps. Only EXACT equality pastes (unlike odc-stac's tolerance-based
`ttol`): a sub-pixel-shifted paste would silently move every pixel by up
to half a cell, so near-misses warp.
