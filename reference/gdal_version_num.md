# GDAL runtime version as an integer `GDAL_VERSION_NUM` (adapter).

`MAJOR*1000000 + MINOR*10000 + REV*100`, so 3.9.0 is `3090000`. `NA` if
it cannot be parsed. garry needs \>= 3.9 for the GTI (GDAL Tile Index)
mosaic driver that backs
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md).

## Usage

``` r
gdal_version_num()
```

## Value

Integer version number, or `NA_integer_`.
