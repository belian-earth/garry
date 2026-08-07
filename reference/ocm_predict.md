# Predict OmniCloudMask classes, natively.

Runs the OCM U-Net over red/green/NIR `LazyRaster`s (same grid, same
graph) and returns per-pixel classes (0 clear, 1 thick cloud, 2 thin
cloud, 3 shadow; NaN at nodata) as a lazy raster: nothing computes until
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md).
For datasets,
[`ocm_mask()`](https://belian-earth.github.io/garry/reference/ocm_mask.md)
derives and applies the mask per slice in one call.

## Usage

``` r
ocm_predict(red, green, nir, model = ocm_model())
```

## Arguments

- red, green, nir:

  Band `LazyRaster`s.

- model:

  An
  [`ocm_model()`](https://belian-earth.github.io/garry/reference/ocm_model.md).

## Value

A class `LazyRaster` on the spatial grid.
