# Build a warped VRT of a source onto an exact target grid.

Delegates every pixel of cross-CRS math to the GDAL warper (decision
D5): `-te`/`-ts` pin the output grid exactly to `target_grid`. Float
targets without a source nodata get `-dstnodata nan` so area outside the
source footprint reads as NaN, not 0 (D8).

## Usage

``` r
gdal_warp_vrt(src_path, band, target_grid, resampling, src_nodata = numeric(0))
```

## Arguments

- src_path:

  Source path/VSI URL.

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
