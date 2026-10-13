# Write a small all-nodata window (failed-fetch placeholder).

Int16 with the sentinel when `nodata` is declared, else Byte 255 (the
HLS QA fill convention): the local mosaic reads a hole where the object
went missing instead of erroring.

## Usage

``` r
gdal_nodata_window(out_file, ext, crs, nodata = numeric(0), nbands = 1L)
```

## Arguments

- out_file:

  Destination GTiff.

- ext, crs:

  Window extent and CRS.

- nodata:

  Length-0 or length-1 sentinel.

- nbands:

  Band count: a multi-band mosaic reading band k from a placeholder with
  fewer bands fails ("has not enough bands"), so the placeholder matches
  the source's count.

## Value

`out_file`, invisibly.
