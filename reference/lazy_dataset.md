# Build a lazy dataset from a STAC source table.

One band per asset, each a time-sliced GTI mosaic pinned to `grid`
(mixed source CRS is fine; the GTI driver reprojects per tile). All
bands share one intermediate representation (IR) graph, so a mask
defined once (see
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md)) is
computed once and dedup'd across bands, and
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
plans the whole dataset in one pass.

## Usage

``` r
lazy_dataset(
  sources,
  grid,
  assets,
  mask_asset = NULL,
  granularity = "day",
  sort_field = "datetime",
  nodata = NULL,
  lon = NULL,
  resampling = "near",
  scale = FALSE,
  offset = NULL
)
```

## Arguments

- sources:

  A STAC `doc_items` (from
  [`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
  optionally filtered) or a
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table.

- grid:

  Target
  [`GridSpec()`](https://belian-earth.github.io/garry/reference/GridSpec.md)
  for every band.

- assets:

  Character vector of value assets to load.

- mask_asset:

  Optional QA/mask asset (e.g. `"Fmask"`, `"SCL"`); loaded alongside the
  value assets and used as the default `from` in
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md).

- granularity:

  Time-slice granularity (see
  [`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)).

- sort_field:

  Index field ordering overlaps within a slice.

- nodata:

  Nodata handling: `NULL` (per-asset file metadata), a scalar (applied
  to every asset), or a named numeric keyed by asset (unnamed assets
  fall back to file metadata). Reflectance and QA bands usually need
  different sentinels, so the named form is typical, e.g.
  `c(B04 = -9999, B03 = -9999, Fmask = 255)`.

- lon:

  Longitude for `granularity = "solar_day"` (see
  [`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)).

- resampling:

  GDAL resampling for the warp-on-read onto `grid`: a scalar (every
  value band) or a named character keyed by asset (unnamed assets fall
  back to `"near"`). `mask_asset` is always read `"near"` regardless,
  since interpolating packed QA bits corrupts them. `"near"` (the
  default) preserves exact source values; use `"bilinear"`, `"average"`,
  `"cubic"`, ... to interpolate. Resample after the fact instead with
  [`align()`](https://belian-earth.github.io/garry/reference/align.md).

- scale:

  Apply each value band's scale/offset at read. `FALSE` (default) reads
  raw digital numbers. `TRUE` discovers the affine from the assets' file
  metadata (the GDAL band scale/offset QGIS applies; one asset per band
  is probed and the collection is assumed homogeneous) and every read
  returns `v * scale + offset`, applied after the nodata sentinel
  becomes NaN. A scalar or named numeric (keyed by asset) supplies
  scales explicitly. Discovery only consults the files themselves: STAC
  metadata is never read, so collections whose files carry no scaling
  metadata (e.g. Planetary Computer Sentinel-2 L2A) read raw and scale
  explicitly instead. `mask_asset` is never scaled.

- offset:

  Explicit additive offset(s) (scalar or named by asset) used when
  `scale` is numeric; defaults to 0. Ignored when `scale` is logical.

## Value

A `LazyDataset`.

## See also

[`lazy_cog()`](https://belian-earth.github.io/garry/reference/lazy_cog.md),
[`group_by_time()`](https://belian-earth.github.io/garry/reference/group_by_time.md),
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
