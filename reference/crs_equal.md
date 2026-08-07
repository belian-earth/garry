# Are two CRS strings the same reference system?

Fast path: identity of canonical WKT. Fallback: PROJ semantic comparison
via gdalraster::srs_is_same().

## Usage

``` r
crs_equal(a, b)
```

## Arguments

- a, b:

  CRS strings (any GDAL-interpretable form).

## Value

`TRUE` or `FALSE`.
