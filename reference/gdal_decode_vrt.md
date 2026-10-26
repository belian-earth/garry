# A lookup-table VRT decoding an 8-bit coded raster (adapter).

Every band of `src` becomes a Float32 band whose ComplexSource maps each
code through `table` (`<LUT>`), with `nodata` masked (`<NODATA>`) and
NaN as the band's nodata: any GDAL read, warp or resampling of the VRT
sees decoded values, and averaging averages them, the order a nonlinear
code needs. The XML is written directly (no `gdalbuildvrt`, which
refuses south-up sources); the geotransform, CRS and band descriptions
are the source's. The read path for every source
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
decodes; an aligned read applies the same table itself
(`.gdal_read_decoded()`).

## Usage

``` r
gdal_decode_vrt(vrt, src, lo, table, nodata = numeric(0))
```

## Arguments

- vrt:

  Output VRT path.

- src:

  The coded raster (Byte or Int8 bands).

- lo:

  The code of `table[[1L]]`.

- table:

  Decoded value of each code from `lo`; NaN entries (the nodata code)
  are left out of the LUT.

- nodata:

  Length-0 or length-1 code to mask.

## Value

`vrt`.
