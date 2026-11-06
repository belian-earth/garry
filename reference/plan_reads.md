# Where a plan reads its sources

Lists the windows a plan's read stages read and the source pixels and
tiles behind each, without reading any pixels. A read stage reads its
grid in windows: the chunks the planner cut, grown to whole read tasks
where
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
would grow them for a plan that only reads. Each window maps onto its
source file by the route that reads it:

## Usage

``` r
plan_reads(x, tiles = FALSE, distributed = garry_daemons_set())
```

## Arguments

- x:

  A `LazyRaster`, a `LazyDataset` (its bands are stacked first, as in
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md))
  or a `Plan` from
  [`plan_lazy()`](https://belian-earth.github.io/garry/reference/plan_lazy.md).

- tiles:

  List one row per source tile, with its bytes, instead of one row per
  window?

- distributed:

  As in
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md):
  whether the plan is read by the daemon pools, which reads a remote
  mosaic by fetching its items.

## Value

A data frame with one row per window: `stage`, `route`, `chunk`, `path`,
`band` (comma-separated for a band stack), `overview`, the window
`x_off`, `y_off`, `x_size`, `y_size` in the stage's grid, halo included,
the source window `src_x_off`, `src_y_off`, `src_x_size`, `src_y_size`
in the file's pixels (rows from the north), and the inclusive tile range
`tile_x0`, `tile_y0`, `tile_x1`, `tile_y1` with the tile size
`tile_x_size`, `tile_y_size` (tile rows count from the file's first row,
the south edge of a south-up file). With `tiles = TRUE`, one row per
window, band and tile in place of the range: `file`, `overview`, `band`,
`tile_x`, `tile_y`, `offset`, `length`.

## Details

- `"read"`: a source read on its own pixels, the window itself.

- `"direct"`: a warp served by a plain or decimating read of the file
  (an aligned target), the window scaled into the file.

- `"warp"`: a warp through GDAL's warper, the box of the window's
  footprint on the source, padded for the resampling kernel as the
  warper pads its source windows.

- `"window_warp"`, `"mosaic"`, `"zarr"`, `"coarsen"`: reads of several
  files, a mosaic (a GTI index, or a local VRT of files placed across
  its extent), a Zarr array or a coarsened warp. Their windows are
  listed, their source windows and tiles are `NA`: each of them reads
  its files in its own pieces.

Tiles are the file's blocks: a COG's tiles, a striped file's strips. A
local VRT reads through to its files and is described by the tiles its
`SourceProperties` record, which holds for a VRT whose bands each take
one file on the VRT's own pixels, such as a classic VRT of a daily
series. A footprint is a box, so a rotated or curved warp lists tiles in
its corners that it does not read.

A read onto a coarse grid reads an overview of its file where the file
has them: a warp the level gdalwarp picked for it, a decimating read the
one GDAL's RasterIO takes (the coarsest no coarser than the read). Its
source window and tiles are then that overview's, numbered in `overview`
(0 the first, `NA` full resolution); finding it opens the file's
overviews.

With `tiles = TRUE` each window becomes one row per source tile, with
the tile's byte `offset` and `length` in its file, from the file's TIFF
metadata (`0` for a tile a sparse file leaves empty). This opens each
file, and a remote file costs its header fetch, if it is not open
already. A VRT's window takes the file under its centre (GDAL's
`LocationInfo`), whose tiles are listed only where it has the VRT's size
and one band.

## See also

[`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md)
for the stages themselves.

## Examples

``` r
f <- system.file("extdata", "storml_elev.tif", package = "gdalraster")
r <- lazy_source(f)
plan_reads(r)
#>   stage route chunk
#> 1     1  read     1
#>                                                                 path band
#> 1 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif    1
#>   overview x_off y_off x_size y_size src_x_off src_y_off src_x_size src_y_size
#> 1       NA     0     0    143    107         0         0        143        107
#>   tile_x0 tile_y0 tile_x1 tile_y1 tile_x_size tile_y_size
#> 1       0       0       0       3         143          28
plan_reads(r, tiles = TRUE)
#>   stage route chunk
#> 1     1  read     1
#> 2     1  read     1
#> 3     1  read     1
#> 4     1  read     1
#>                                                                 path
#> 1 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif
#> 2 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif
#> 3 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif
#> 4 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif
#>                                                                 file overview
#> 1 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif       NA
#> 2 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif       NA
#> 3 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif       NA
#> 4 /home/runner/work/_temp/Library/gdalraster/extdata/storml_elev.tif       NA
#>   band tile_x tile_y offset length
#> 1    1      0      0    526   5012
#> 2    1      0      1   5538   4996
#> 3    1      0      2  10534   5183
#> 4    1      0      3  15717   4326
```
