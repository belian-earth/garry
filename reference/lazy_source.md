# Build a LazyRaster from a GDAL source.

Grid, dtype, native block size, and file nodata come from GDAL via the
adapter
([`gdal_grid_spec()`](https://belian-earth.github.io/garry/reference/gdal_grid_spec.md)).
A user-supplied `nodata` overrides the file's. An integer source with
nodata is promoted to f32 so NaN can carry nodata downstream (decision
D8); the sentinel-to-NaN rewrite happens at read time in the adapter.

## Usage

``` r
lazy_source(
  path,
  band = 1L,
  graph = graph_new(),
  nodata = NULL,
  open_options = character(0),
  grid = NULL,
  block_dim = NULL,
  resampling = "near",
  scale = FALSE,
  offset = NULL
)
```

## Arguments

- path:

  Path or VSI URL readable by GDAL.

- band:

  1-based band index.

- graph:

  `Graph` to add the source to; defaults to a fresh graph.

- nodata:

  Optional nodata sentinel overriding the file metadata.

- open_options:

  GDAL open options ("KEY=VALUE"), e.g. a GTI `FILTER` selecting one
  time slice of a tile index.

- grid:

  Optional `GridSpec` declaring the source's grid and dtype, skipping
  metadata discovery (see Details).

- block_dim:

  Optional native block size (x, y), only meaningful with `grid`;
  defaults to unconstrained.

- resampling:

  GDAL resampling used when a read reprojects or rescales this source
  onto the analysis grid. `"near"` (default) preserves exact source
  values; use `"bilinear"`, `"average"`, `"cubic"`, ... to interpolate.

- scale:

  Apply the band's scale/offset at read. `FALSE` (default) reads raw
  values. `TRUE` discovers the affine from the file's band metadata (the
  GDAL scale/offset QGIS applies) and every read returns
  `v * scale + offset`, applied after the nodata sentinel becomes NaN. A
  length-1 numeric supplies the scale explicitly (with `offset`),
  skipping discovery. Discovery only consults the file: STAC-side
  metadata is never read.

- offset:

  Explicit additive offset used when `scale` is numeric; defaults to 0.
  Ignored when `scale` is logical.

## Value

A `LazyRaster`.

## Details

Passing `grid` skips the GDAL open entirely: no metadata is read until
execution. Use it when the dataset's grid is known by construction, e.g.
GTI mosaics pinned to a target grid via
[`gti_open_options()`](https://belian-earth.github.io/garry/reference/gti_open_options.md),
where opening every time slice just to rediscover the grid costs a
remote COG header fetch per slice (measured: ~0.1 s each, serial, on the
host). `grid` must describe the dataset exactly as `path` +
`open_options` open it, including the source dtype; it is trusted, not
checked. With `grid` given, file nodata is NOT consulted (pass `nodata`
explicitly if the source has a sentinel).
