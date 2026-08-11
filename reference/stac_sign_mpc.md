# Sign Planetary Computer STAC items, caching the token per collection.

Microsoft Planetary Computer assets need a SAS token appended to each
asset href before they can be read. Unlike `rstac::items_sign()`, which
requests a token on every call and can storm the MPC signing endpoint
into 429s when signing many items, `stac_sign_mpc()` caches the
**collection-level** token in memory AND on disk (under
[`tools::R_user_dir()`](https://rdrr.io/r/tools/userdir.html)) and
reuses it until it expires (`msft:expiry`) – one request per collection
instead of one per item. Use it in place of `rstac::items_sign()` after
[`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md).

## Usage

``` r
stac_sign_mpc(items, subscription_key = Sys.getenv("MPC_TOKEN", unset = NA))
```

## Arguments

- items:

  An rstac `doc_items` from
  [`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md).

- subscription_key:

  Optional MPC subscription key (defaults to the `MPC_TOKEN` environment
  variable). Not required for public data.

## Value

`items` with every asset href signed.

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
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
