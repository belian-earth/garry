# Extract raster values at points (adapter).

D13: the only home for the
[`gdalraster::pixel_extract`](https://firelab.github.io/gdalraster/reference/pixel_extract.html)
call. Handles interpolation, kernel windows, point reprojection and the
RAM guard itself, and reads only the blocks holding points – so garry
delegates rather than reimplementing any of it.

## Usage

``` r
gdal_pixel_extract(raster, ...)
```

## Arguments

- raster:

  Path or `GDALRaster` object.

- ...:

  Passed to
  [`gdalraster::pixel_extract()`](https://firelab.github.io/gdalraster/reference/pixel_extract.html).

## Value

As
[`gdalraster::pixel_extract()`](https://firelab.github.io/gdalraster/reference/pixel_extract.html).
