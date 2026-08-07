# Filter a source table by maximum cloud cover.

Filter a source table by maximum cloud cover.

## Usage

``` r
stac_filter_cloud(sources, max_cloud_cover)
```

## Arguments

- sources:

  A
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table.

- max_cloud_cover:

  Keep rows strictly below this percentage (rows with unknown cloud
  cover are kept).

## Value

The filtered table.
