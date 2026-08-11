# Query a STAC API and return the item collection.

Searches the collection with a GET request, falling back to POST when
the API rejects GET, and fetches every page of results via
`rstac::items_fetch()`.

## Usage

``` r
stac_query(bbox, stac_source, collection, start_date, end_date, limit = 999)
```

## Arguments

- bbox:

  Length-4 numeric, EPSG:4326 (xmin, ymin, xmax, ymax).

- stac_source:

  STAC API root URL.

- collection:

  Collection id.

- start_date, end_date:

  Dates (any lubridate-parseable form).

- limit:

  Page size requested from the API.

## Value

An rstac `doc_items` object.

## See also

[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
and
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
as the usual next steps.

Other stac helpers:
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
[`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md),
[`stac_filter_assets()`](https://belian-earth.github.io/garry/reference/stac_filter_assets.md),
[`stac_filter_cloud()`](https://belian-earth.github.io/garry/reference/stac_filter_cloud.md),
[`stac_filter_coverage()`](https://belian-earth.github.io/garry/reference/stac_filter_coverage.md),
[`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md),
[`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md),
[`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md),
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md),
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
