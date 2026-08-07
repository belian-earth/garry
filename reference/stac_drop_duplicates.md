# Drop duplicate acquisitions (identical footprint and datetime).

Duplicate items are a known Planetary Computer quirk; equality uses the
footprint rounded to 4 decimal places plus the datetime, per asset
(vrtility's rule).

## Usage

``` r
stac_drop_duplicates(sources)
```

## Arguments

- sources:

  A
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table.

## Value

The deduplicated table.
