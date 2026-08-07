# Stage a GDAL raster as a raw-BSQ cube (`.bin` + sibling `.vrt`).

Reads every band of `src` and writes garry's raw cube format:
band-sequential f32/f64 planes in a `.bin`, described by a
`VRTRawRasterBand` VRT that carries the georeference. Any GDAL consumer
reads the VRT normally; garry's reader recognises the shape and reads
the bin directly (measured ~9x on a 73-band cube — GDAL's tile walk
costs ~2.2 s per 482 MB window regardless of compression, the raw read
0.24 s). Use it once on pipeline intermediates that are read many times
(per-year context cubes, prediction stacks).

## Usage

``` r
stage_raw_cube(src, dst_vrt, slab_rows = 512L)
```

## Arguments

- src:

  Source path readable by GDAL.

- dst_vrt:

  Destination `.vrt` path (the `.bin` lands beside it).

- slab_rows:

  Rows per read/write slab (memory bound).

## Value

`dst_vrt`, invisibly.
