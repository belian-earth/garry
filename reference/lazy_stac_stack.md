# Lazy time-sliced stack of one STAC asset on a target grid.

Builds a GTI index for `asset`, then opens one mosaic per time slice
pinned to `grid` (mixed source CRS is fine: the GTI driver reprojects
per tile) and stacks them along `t`. Overlaps within a slice resolve by
ascending `sort_field` (highest drawn on top).

## Usage

``` r
lazy_stac_stack(
  sources,
  grid,
  asset,
  granularity = "day",
  sort_field = "datetime",
  nodata = NULL,
  lon = NULL
)
```

## Arguments

- sources:

  A
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table.

- grid:

  Target `GridSpec` for every slice.

- asset:

  Asset name to stack.

- granularity:

  Slice granularity (see
  [`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)).

- sort_field:

  Index field ordering overlaps within a slice.

- nodata:

  Optional nodata override passed to each slice source.

- lon:

  Longitude for `granularity = "solar_day"` (see
  [`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)).

## Value

A list: `stack` (`LazyRaster`), `slices` (character), `index` (path).
