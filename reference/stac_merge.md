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

## See also

Other stac helpers:
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
[`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md),
[`stac_filter_assets()`](https://belian-earth.github.io/garry/reference/stac_filter_assets.md),
[`stac_filter_cloud()`](https://belian-earth.github.io/garry/reference/stac_filter_cloud.md),
[`stac_filter_coverage()`](https://belian-earth.github.io/garry/reference/stac_filter_coverage.md),
[`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md),
[`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md),
[`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md),
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
