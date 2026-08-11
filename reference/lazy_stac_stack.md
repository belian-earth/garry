# Lazy time-sliced stack of one STAC asset on a target grid.

Builds a GTI (GDAL Tile Index; see
[`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md))
index for `asset`, then opens one mosaic per time slice pinned to `grid`
(mixed source CRS is fine: the GTI driver reprojects per tile) and
stacks them along `t`. Overlaps within a slice resolve by ascending
`sort_field` (highest drawn on top).

## Usage

``` r
lazy_stac_stack(
  sources,
  grid,
  asset,
  granularity = "day",
  sort_field = "datetime",
  nodata = NULL,
  lon = NULL,
  scale = FALSE,
  offset = NULL
)
```

## Arguments

- sources:

  A
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table.

- grid:

  Target
  [`GridSpec()`](https://belian-earth.github.io/garry/reference/GridSpec.md)
  for every slice.

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

- scale, offset:

  Read affine, as in
  [`lazy_source()`](https://belian-earth.github.io/garry/reference/lazy_source.md):
  `FALSE` (default) reads raw values, `TRUE` discovers the file's band
  scale/offset (probing the mosaic, then the first item), a numeric
  supplies it explicitly.

## Value

A list: `stack` (`LazyRaster`), `slices` (character), `index` (path).

## See also

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
to materialise the stack;
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md),
the higher-level multi-band interface most users want.

Other stac helpers:
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
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
