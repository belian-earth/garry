# Rename assets to a common band schema.

Harmonising collections that name the same physical band differently
(e.g. HLS Landsat `B05` and HLS Sentinel-2 `B8A` are both the narrow
NIR): supply a `c(old = new)` map and the `asset` column is rewritten to
the shared names. Assets absent from the map are dropped by default, so
the map doubles as the band selector. Include identity entries
(`Fmask = "Fmask"`) to keep a band under its own name.

## Usage

``` r
stac_rename_assets(sources, mapping, drop_unmapped = TRUE)
```

## Arguments

- sources:

  A
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table.

- mapping:

  Named character `c(old = new)`: original asset -\> common name.

- drop_unmapped:

  Drop assets not named in `mapping` (default `TRUE`)? When `FALSE`,
  unmapped assets pass through unchanged.

## Value

The table with a rewritten `asset` column.

## Details

After renaming,
[`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md)
concatenates the collections into one table. A band a collection lacks
needs no placeholder:
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
gives each band only the slices that carry it, and
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md) pairs
those slices with the QA band by name (a Landsat-only thermal band masks
against the Landsat Fmask slices), so ragged bands reduce over exactly
their own observations.

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
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
