# Convert a collected result to a terra SpatRaster.

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
results carry a `gis` attribute (bbox, CRS, dims); this wraps the array
as a `terra::SpatRaster` for hand-off to the terra ecosystem (plotting,
zonal statistics, vector ops). Layers are named after the dataset's
bands, or a stack's labels, when the result has them (`gis$band_names`).

## Usage

``` r
as_terra(x)
```

## Arguments

- x:

  A matrix or `(y, x, band)` array from
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
  (must carry the `gis` attribute).

## Value

A `terra::SpatRaster`.
