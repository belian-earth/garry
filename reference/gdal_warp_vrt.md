# Build a warped VRT of a source onto an exact target grid.

Delegates every pixel of cross-CRS math to the GDAL warper: `-te`/`-ts`
pin the output grid exactly to `target_grid`. A source nodata goes to
the warper as both `-srcnodata` and `-dstnodata`, so it never enters
resampling and area outside the source footprint reads as nodata; float
targets without one get `-dstnodata nan`.

## Usage

``` r
gdal_warp_vrt(src_path, band, target_grid, resampling, src_nodata = numeric(0))
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

## Value

Path to the VRT file (in
[`tempdir()`](https://rdrr.io/r/base/tempfile.html)).
