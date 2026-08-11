# Keep only the named assets in a STAC item collection (or sources table).

Drops every other asset from each item – fewer assets to carry through
the pipeline, and fewer to sign. Apply it BEFORE
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md)
so only the assets you keep get a token (MPC returns every band plus
thumbnails and rendered previews). Items left with none of the requested
assets are dropped. Polymorphic: a STAC `doc_items` or a
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
table.

## Usage

``` r
stac_filter_assets(sources, assets)
```

## Arguments

- sources:

  A STAC `doc_items` or a
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  data frame.

- assets:

  Asset names to keep.

## Value

The filtered `doc_items` / data frame.

## See also

Other stac helpers:
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
[`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md),
[`stac_filter_cloud()`](https://belian-earth.github.io/garry/reference/stac_filter_cloud.md),
[`stac_filter_coverage()`](https://belian-earth.github.io/garry/reference/stac_filter_coverage.md),
[`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md),
[`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md),
[`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md),
[`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md),
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
