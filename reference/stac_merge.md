# Concatenate source tables into one harmonised collection.

Row-binds
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
tables (typically after
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md)
has brought them onto a shared band schema) and re-sorts. Every table
must carry the same columns. Same-`slice` acquisitions from different
collections co-mosaic (use `granularity = "exact"` downstream to keep
them as separate time steps).

## Usage

``` r
stac_merge(...)
```

## Arguments

- ...:

  Two or more
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  tables (or a single list of them).

## Value

One combined table.
