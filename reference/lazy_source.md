# Build a LazyRaster from a GDAL source.

Grid, dtype, native block size, and file nodata come from GDAL via the
adapter
([`gdal_grid_spec()`](https://belian-earth.github.io/garry/reference/gdal_grid_spec.md)).
A user-supplied `nodata` overrides the file's. An integer source with
nodata is promoted to the float that holds it (f32 up to 16 bits, else
f64) so NaN can carry nodata downstream; the sentinel-to-NaN rewrite
happens at read time in the adapter. An integer source without nodata
has nowhere to put a missing cell, so a compute stage that meets one (a
failed read, a cell no tile reaches, a cell a warp leaves past the
source's footprint) fails: declare `nodata` where cells can be missing.
An Int32 cell holding `-2147483648` reads as missing, `nodata` or not:
gdalraster returns R integers, and that value is R's `NA_integer_`.

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
  offset = NULL,
  name = NULL,
  decode = NULL
)
```

## Arguments

- path:

  Path or VSI URL readable by GDAL. A relative path is taken against the
  working directory here, so a later
  [`setwd()`](https://rdrr.io/r/base/getwd.html) or a pool started
  elsewhere reads the same file.

- band:

  1-based band index.

- graph:

  `Graph` to add the source to; defaults to a fresh graph.

- nodata:

  Optional nodata sentinel replacing the file's: cells holding the
  file's own sentinel then read as data. A tile index, a source opened
  with `open_options` or a source given `grid` masks its own sentinel as
  well.

- open_options:

  GDAL open options ("KEY=VALUE"), e.g. a GTI `FILTER` selecting one
  time slice of a tile index. They apply to one source, and not to a
  decoded one.

- grid:

  Optional `GridSpec` declaring the source's grid and dtype, skipping
  metadata discovery (see Details).

- block_dim:

  Optional block size (x, y) the chunks snap to, in place of the file's
  own. With `grid`, the default is unconstrained.

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
  metadata is never read. A band that reports none warns and reads raw.

- offset:

  Explicit additive offset used when `scale` is numeric; defaults to 0.
  Ignored when `scale` is logical.

- name:

  Optional display name (e.g. the asset or band name). Pure metadata:
  surfaced by
  [`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md)
  and diagnostics, never read by the planner or executors.
  [`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
  sets it to the asset/band name automatically.

- decode:

  Optional function decoding the band's 8-bit codes before any
  resampling, as in
  [`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md);
  `nodata` is then the code to mask.

## Value

A `LazyRaster`.

## Details

Passing `grid` skips the GDAL open entirely: no metadata is read until
execution. Use it when the dataset's grid is known by construction, e.g.
GTI mosaics pinned to a target grid via
[`gti_open_options()`](https://belian-earth.github.io/garry/reference/gti_open_options.md),
where opening every time slice just to rediscover the grid costs a
serial remote COG header fetch per slice. `grid` must describe the
dataset exactly as `path` + `open_options` open it, including the source
dtype; it is trusted, not checked. With `grid` given, the file's nodata
is not read, so pass `nodata` if the source has a sentinel, and pass
that sentinel: a plain read masks the file's own sentinel whatever the
node says, and a warp sees only the value given. A warp also opens the
file: only a source that has been opened can show that it stores the
same type and row order as the file whose warped VRT it would take.

## See also

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md),
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)

## Examples

``` r
f <- system.file("extdata", "garry-example.tif", package = "garry")
red <- lazy_source(f, band = 1L)
red
#> ── <LazyRaster> source  60×40 f32 ──────────────────────────────────────────────
#>   grid   60 x 40 • f32
#>   crs    EPSG:32610
#>   graph  1 nodes • lazy
#>   ℹ plan_draw(x) to see the pipeline
dim(red)
#>  y  x 
#> 40 60 
```
