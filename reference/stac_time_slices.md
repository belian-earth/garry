# Group acquisitions into time slices.

Adds a `slice` column (the datetime truncated to `granularity`); tiles
sharing a slice mosaic together in
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md).

## Usage

``` r
stac_time_slices(
  sources,
  granularity = c("day", "month", "exact", "solar_day"),
  lon = NULL
)
```

## Arguments

- sources:

  A
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table.

- granularity:

  "day", "month", "exact", or "solar_day".

- lon:

  Longitude (degrees, WGS84) whose solar time defines `"solar_day"`: use
  the centre of the analysis area. Defaults to the circular mean of the
  source footprint centres (safe across the antimeridian).

## Value

The table with a `slice` column.

## Details

`"day"` truncates the UTC datetime: one satellite overpass that crosses
local midnight in UTC terms splits into two slices. `"solar_day"`
instead shifts each timestamp by a longitude-dependent solar-time offset
of `lon` degrees x 240 s (as used by odc-stac) before taking the date,
so acquisitions group by the local day of the overpass; the two agree
everywhere except within ~an overpass of the UTC date line at `lon`.

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
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
