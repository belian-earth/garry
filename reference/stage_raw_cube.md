# Stage a GDAL raster as a raw-BSQ cube (`.bin` + sibling `.vrt`).

Reads every band of `src` and writes garry's raw cube format:
band-sequential f32/f64 planes in a `.bin`, described by a
`VRTRawRasterBand` VRT that carries the georeference. Any GDAL consumer
reads the VRT normally; garry's reader recognises the shape and reads
the bin directly, which is many times faster than walking the tiled
GeoTIFF. Use it once on pipeline intermediates that are read many times
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

## See also

[`gdal_create_output()`](https://belian-earth.github.io/garry/reference/gdal_create_output.md)
