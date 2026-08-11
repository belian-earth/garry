# Filter a source table by maximum cloud cover.

Filter a source table by maximum cloud cover.

## Usage

``` r
stac_filter_cloud(sources, max_cloud_cover)
```

## Arguments

- sources:

  A STAC `doc_items` or a
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  data frame.

- max_cloud_cover:

  Keep items strictly below this percentage (items with unknown cloud
  cover are kept).

## Value

The filtered `doc_items` / data frame.

## See also

Other stac helpers:
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
[`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md),
[`stac_filter_assets()`](https://belian-earth.github.io/garry/reference/stac_filter_assets.md),
[`stac_filter_coverage()`](https://belian-earth.github.io/garry/reference/stac_filter_coverage.md),
[`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md),
[`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md),
[`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md),
[`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md),
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
