# Rectangularise STAC items into a source table.

One row per item x asset. The result is a plain data frame: the
`stac_filter_*` helpers operate on it in ordinary R, and
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
/
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md)
consume it to build lazy mosaics.

## Usage

``` r
stac_sources(items, assets = NULL)
```

## Arguments

- items:

  An rstac `doc_items` object (or any list with the same `features`
  structure).

- assets:

  Optional character vector restricting assets.

## Value

A data.frame with one row per item x asset and columns `item_id`,
`asset`, `location` (GDAL-readable href), `datetime`, `cloud_cover`, and
the footprint columns `xmin`, `ymin`, `xmax`, `ymax` (EPSG:4326, from
the item bbox), sorted by datetime, item and asset.

## See also

Other stac helpers:
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
[`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md),
[`stac_filter_assets()`](https://belian-earth.github.io/garry/reference/stac_filter_assets.md),
[`stac_filter_cloud()`](https://belian-earth.github.io/garry/reference/stac_filter_cloud.md),
[`stac_filter_coverage()`](https://belian-earth.github.io/garry/reference/stac_filter_coverage.md),
[`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md),
[`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md),
[`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md),
[`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md),
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
