# Build a warped VRT of a source onto an exact target grid.

Delegates every pixel of cross-CRS math to the GDAL warper: `-te`/`-ts`
pin the output grid exactly to `target_grid`. GDAL's default tolerance
applies, 0.125 source pixels, or none under `garry.warp_exact = TRUE`. A
source nodata goes to the warper as `-srcnodata`, so it never enters
resampling. Area outside the source footprint reads as nodata
(`.warp_dst_nodata()`).

## Usage

``` r
gdal_warp_vrt(
  src_path,
  band,
  target_grid,
  resampling,
  src_nodata = numeric(0),
  open_options = character(0),
  alike = NULL
)
```

## Arguments

- src_path:

  Source path/VSI URL. One source: gdalwarp writes a VRT from a single
  input only. A multi-path source node is read by `gdal_warp_window()`
  instead.

- band:

  1-based source band (the VRT has this single band).

- target_grid:

  `GridSpec` to warp onto.

- resampling:

  GDAL resampling method name.

- src_nodata:

  Source sentinel (length 0 or 1), from the SourceNode.

- open_options:

  GDAL open options of the source ("KEY=VALUE"). The VRT records them,
  so every read of it opens the same source.

- alike:

  What makes sources warp alike: two sources with the same `alike`
  differ only in their name, so the second takes the first's VRT with
  its source renamed and is never opened here. It must cover what the
  VRT takes from the file, its type and row order among them
  (`.warp_read_plan()`). `NULL` builds.

## Value

Path to the VRT file (in
[`tempdir()`](https://rdrr.io/r/base/tempfile.html)).
