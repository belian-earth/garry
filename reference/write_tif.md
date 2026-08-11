# Execute a lazy raster and stream it to a GeoTIFF.

The file-writing sibling of
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md):
executes the plan (same routes, same daemons) and streams the result to
`path` chunk by chunk, so the full raster never sits in memory. Returns
the path invisibly;
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
always returns the in-session array.

## Usage

``` r
write_tif(
  x,
  path,
  dtype = NULL,
  scale = NULL,
  offset = NULL,
  nodata = NULL,
  cog = FALSE,
  creation_options = NULL,
  overview_resampling = c("average", "nearest", "bilinear", "cubic", "mode", "rms"),
  band_names = NULL,
  distributed = garry_daemons_set()
)
```

## Arguments

- x:

  A `LazyRaster`, a `LazyDataset` (bands assembled along the band axis),
  a named list of lazy rasters (multi-export: one plan, one file per
  sink), or a `LazyDatasetGroups` (the result of
  [`group_by_time()`](https://belian-earth.github.io/garry/reference/group_by_time.md);
  one file per group via a `{group}` placeholder in `path`).

- path:

  Destination path. For a named-list input: a directory (files named
  `<sink>.tif`) or a named character vector keyed by sink.

- dtype:

  Output dtype override (e.g. `"i16"`, `"u8"`); default keeps the plan's
  dtype (usually `"f32"`).

- scale, offset:

  Quantization affine (see Details). Requires an integer `dtype`;
  `offset` defaults to 0.

- nodata:

  Sentinel written to the file and used for NaN demotion, in stored (DN)
  units. Required when an integer `dtype` output can contain NaN.

- cog:

  Write a Cloud Optimized GeoTIFF (see Details).

- creation_options:

  GDAL creation options (`"KEY=VALUE"`). With `cog = FALSE` these
  replace the default tiled-DEFLATE options of the streamed write; with
  `cog = TRUE` they go to the COG translate pass (the temporary streamed
  file keeps the defaults).

- overview_resampling:

  COG overview resampling (`cog = TRUE` only). `"average"` (default)
  suits continuous data; use `"nearest"` for categorical outputs like
  masks.

- band_names:

  As in
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md).

- distributed:

  As in
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md).

## Value

The written path(s), invisibly (expanded per sink/group for list,
directory, and `{group}` forms).

## Details

`dtype` with `scale`/`offset` quantizes at the sink boundary: values are
stored as `round((v - offset) / scale)` (round half to even) and the
affine is written as band scale/offset metadata, so GDAL readers (QGIS,
`lazy_source(scale = TRUE)`) recover physical values. An int16
reflectance file is half the raw bytes of float32 and compresses far
better. NaN demotes to `nodata`, which is stored in DN units and must
sit outside the quantized data range.

`cog = TRUE` streams to a temporary tiled GeoTIFF beside `path`, then
finalises with one `gdal_translate` pass to the COG driver (which is
copy-only by design: overviews precede full-res data). The extra
sequential pass is the trade every COG producer makes; the temporary
file is removed even on failure, so `path` never holds a half-written
COG.

## See also

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
to return the result in the R session;
[`materialise()`](https://belian-earth.github.io/garry/reference/materialise.md)
to checkpoint to local cubes and stay lazy.
