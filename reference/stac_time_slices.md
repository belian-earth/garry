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

  Longitude (degrees, WGS84) whose solar time defines `"solar_day"` —
  use the centre of the analysis area. Defaults to the circular mean of
  the source footprint centres (safe across the antimeridian).

## Value

The table with a `slice` column.

## Details

`"day"` truncates the UTC datetime: one satellite overpass that crosses
local midnight in UTC terms splits into two slices. `"solar_day"`
instead shifts each timestamp by the local solar offset (`lon` degrees x
240 s, the odc-stac rule) before taking the date, so acquisitions group
by the local day of the overpass; the two agree everywhere except within
~an overpass of the UTC date line at `lon`.
