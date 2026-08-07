# Convert a collected result to a terra SpatRaster.

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
results carry a `gis` attribute (bbox, CRS, dims); this wraps the array
as a `terra::SpatRaster` for hand-off to the terra ecosystem (plotting,
zonal statistics, vector ops). Band names/descriptions are preserved
when present.

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
