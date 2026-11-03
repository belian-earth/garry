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
stage_raw_cube(src, dst_vrt)
```

## Arguments

- src:

  Source path readable by GDAL.

- dst_vrt:

  Destination `.vrt` path (the `.bin` lands beside it).

## Value

`dst_vrt`, invisibly.

## Details

As for every write (see
[`write_tif()`](https://belian-earth.github.io/garry/reference/write_tif.md)),
the cube builds beside its target and replaces it only when complete, so
`src` may be the cube itself, and a failure leaves the target as it was.

## See also

[`gdal_create_output()`](https://belian-earth.github.io/garry/reference/gdal_create_output.md)
