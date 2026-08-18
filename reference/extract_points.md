# Extract raster values at points.

Samples a raster at points via
[`gdalraster::pixel_extract()`](https://firelab.github.io/gdalraster/reference/pixel_extract.html),
which reads only the blocks containing points. Accepts anything that
function accepts (a path or a `GDALRaster`, passed through untouched)
plus a garry `LazyRaster`/`LazyDataset` that is already **materialised**
– i.e. one whose graph is a bare source over local files, as
[`materialise()`](https://belian-earth.github.io/garry/reference/materialise.md)
returns.

## Usage

``` r
extract_points(raster, xy, bands = NULL, interp = NULL, ...)
```

## Arguments

- raster:

  A `LazyRaster`, `LazyDataset`, raster path, or `GDALRaster` object.

- xy:

  Points: a
  [`wk::xy()`](https://paleolimbot.github.io/wk/reference/xy.html)
  vector (its CRS supplies `xy_srs`), or a two-column matrix/data frame
  as gdalraster expects.

- bands:

  Bands to extract (default all).

- interp:

  Interpolation: `NULL`/`"nearest"` (default), `"bilinear"`, `"cubic"`,
  `"cubicspline"`.

- ...:

  Passed to
  [`gdalraster::pixel_extract()`](https://firelab.github.io/gdalraster/reference/pixel_extract.html)
  (`krnl_dim`, `xy_srs`, `max_ram`, `as_data_frame`).

## Value

As
[`gdalraster::pixel_extract()`](https://firelab.github.io/gdalraster/reference/pixel_extract.html):
a matrix, or a data frame with `as_data_frame = TRUE`.

## Details

An unmaterialised pipeline is an error, not a silent cube write. Getting
pixels onto disk costs real time and space, and the cube is almost
always wanted again (for the predict pass, say), so the caller should
own that step:

    cube <- materialise(pipeline)     # explicit, reusable
    vals <- extract_points(cube, pts)

`xy` may be a
[`wk::xy()`](https://paleolimbot.github.io/wk/reference/xy.html) point
vector, in which case its CRS supplies `xy_srs` and GDAL reprojects as
needed; a matrix or data frame behaves exactly as in gdalraster.

## See also

[`materialise()`](https://belian-earth.github.io/garry/reference/materialise.md),
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)

## Examples

``` r
if (FALSE) { # \dontrun{
pts <- wk::xy(c(512300, 514800), c(4600100, 4601900), crs = "EPSG:32632")
cube <- materialise(composite)
extract_points(cube, pts, interp = "bilinear")
extract_points("composite.tif", pts)   # a path works too
} # }
```
