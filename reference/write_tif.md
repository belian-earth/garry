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
  replace the default tiled-DEFLATE options of the streamed write
  (compression stays multi-threaded unless they set `NUM_THREADS`); with
  `cog = TRUE` they go to the COG translate pass (the temporary streamed
  file keeps the defaults).

- overview_resampling:

  COG overview resampling (`cog = TRUE` only). `"average"` (default)
  suits continuous data; use `"nearest"` for categorical outputs like
  masks.

- band_names:

  Band descriptions written to the file, one per output band. Defaults
  to the dataset's band names, or the labels of a `band` stack; given,
  it takes precedence over both.

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

Integer outputs saturate: a value beyond the dtype's range is written as
the nearest limit, without a warning. When `nodata` is one of those
limits, quantized values saturate one step inside it, so they never read
back as nodata; choose `scale` and `offset` so the data fits.

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

## Examples

``` r
f <- system.file("extdata", "garry-example.tif", package = "garry")
red <- lazy_source(f, band = 1L)
nir <- lazy_source(f, band = 3L)
out <- tempfile(fileext = ".tif")
write_tif((nir - red) / (nir + red), out)
#> Error in confirm_plugin_install(platform, url): The "cpu" PJRT plugin needs to be downloaded for pjrt to work.
#> ℹ Automatic downloads are not performed in non-interactive sessions.
#> ℹ Set `PJRT_INSTALL` to "1" to allow the download, or set
#>   `PJRT_PLUGIN_PATH_CPU` to a local plugin file.
file.exists(out)
#> [1] FALSE
```
