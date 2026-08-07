# Create an output raster for a grid.

A single non-spatial dim ("t" or "band") maps to bands; more than one is
an error. A `.tif` destination writes a tiled GTiff; a `.vrt`
destination writes a raw-BSQ cube (`.bin` + sibling `VRTRawRasterBand`
VRT — the intermediate format whose reads bypass GDAL's tile machinery;
see
[`stage_raw_cube()`](https://belian-earth.github.io/garry/reference/stage_raw_cube.md)).

## Usage

``` r
gdal_create_output(
  path,
  grid,
  nodata = numeric(0),
  options = NULL,
  band_names = NULL,
  dtype = NULL,
  scale = numeric(0),
  offset = numeric(0)
)
```

## Arguments

- path:

  Destination path.

- grid:

  Output `GridSpec`.

- nodata:

  Optional sentinel to record in metadata (all bands).

- options:

  GTiff creation options. `NULL` (default) uses tiled DEFLATE
  (`TILED=YES`, 256x256 blocks, `BIGTIFF=IF_SAFER`) plus
  `INTERLEAVE=BAND` for multi-band grids. Band interleave matters:
  GDAL's GTiff defaults (pixel interleave, full-width 1-row strips) make
  every later per-band read decompress ALL bands of each strip, which
  amplifies read cost by the band count on files garry itself wrote.

- band_names:

  Optional character vector of band descriptions, in band order; written
  as each band's GDAL description (shows in `gdalinfo`).

- dtype:

  Optional dtype override for the created file (else the grid's dtype).

- scale, offset:

  Optional band scale/offset metadata written on every band, so readers
  (QGIS, GDAL, `scale = TRUE` reads) recover `stored * scale + offset`.

## Value

An open dataset object; caller must `$close()`.
