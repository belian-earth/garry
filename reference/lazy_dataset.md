# Build a lazy dataset from a STAC source table or raster file(s).

The one way into any source. Two input forms:

## Usage

``` r
lazy_dataset(
  sources,
  grid = NULL,
  assets = NULL,
  mask_asset = NULL,
  granularity = "day",
  sort_field = "datetime",
  nodata = NULL,
  lon = NULL,
  resampling = "near",
  scale = FALSE,
  offset = NULL,
  bands = NULL
)
```

## Arguments

- sources:

  A STAC `doc_items` (from
  [`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
  optionally filtered), a
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table, or a character path / vector of paths to (multi-band) raster
  file(s) – local, `/vsicurl/`, or bare `http(s)://` (prefixed
  automatically).

- grid:

  Target
  [`GridSpec()`](https://belian-earth.github.io/garry/reference/GridSpec.md)
  for every band. Required for the table form; `NULL` (the default)
  keeps the file form on its native grid.

- assets:

  Character vector of value assets to load (table form), or of band
  names to select (file form, when the file carries band descriptions).

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

- bands:

  File form only: integer source band indices to select (default: all).
  Mutually exclusive with `assets`.

## Value

A `LazyDataset`.

## Details

- a STAC `doc_items` /
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table: one band per asset, each a time-sliced GTI mosaic pinned to
  `grid` (mixed source CRS is fine; the GTI driver reprojects per tile).

- a character path (or vector of same-CRS tile paths, mosaicked): one
  band per file band, one time slice. This is the multi-band raster
  entry – geo-embedding stacks (e.g. Alpha Earth's 64-band tiles), Zarr
  via the GDAL driver, any multi-band file GDAL reads. Each band is its
  own source, so reads fan out band-by-band across the reader pool
  (per-band tasks through per-daemon handles: the measured fastest
  remote shape, design/gdal-multiband-fanout.md). Bands are named by
  their file band descriptions when present, else `b<index>`;
  `grid = NULL` stays on the file's native grid, and a supplied `grid`
  inserts an
  [`align()`](https://belian-earth.github.io/garry/reference/align.md)
  warp per band. Value transforms (e.g.
  [`dequantize_aef()`](https://belian-earth.github.io/garry/reference/dequantize_aef.md))
  go downstream as
  [`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md)s,
  which fuse onto the read at
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md).

All bands share one intermediate representation (IR) graph, so a mask
defined once (see
[`mask()`](https://belian-earth.github.io/garry/reference/mask.md)) is
computed once and dedup'd across bands, and
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
plans the whole dataset in one pass.

## See also

[`group_by_time()`](https://belian-earth.github.io/garry/reference/group_by_time.md),
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
