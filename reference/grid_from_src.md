# Build an analysis grid from a raster or vector source.

Derives a `GridSpec` from any GDAL/OGR-readable file or URL. The two
source kinds are treated differently, because they carry different
information:

## Usage

``` r
grid_from_src(
  x,
  res,
  projection = c("laea", "aeqd", "utm", "pconic", "eqdc"),
  ellps = "WGS84",
  buffer = 0,
  dtype = "f32"
)
```

## Arguments

- x:

  Path or URL to a raster or vector source.

- res:

  Target resolution. For a raster, in the source's native CRS units; for
  a vector, in the chosen projected CRS units (see
  [`grid_from_bbox()`](https://belian-earth.github.io/garry/reference/grid_from_bbox.md)).

- projection, ellps:

  Vector sources only; ignored for rasters.

- buffer, dtype:

  As in
  [`grid_from_bbox()`](https://belian-earth.github.io/garry/reference/grid_from_bbox.md).

## Value

A `GridSpec`.

## Details

- **Raster** (GeoTIFF, COG, ...): the source already has a projected CRS
  and footprint, so the grid keeps that native CRS and extent and is
  simply re-gridded to `res` (the extent is snapped out to whole
  multiples of `res`). `projection`/`ellps` are ignored: reprojecting a
  raster's own grid would distort it. Use this to coarsen a tile in
  place, e.g. read a 10 m embedding COG onto a 30 m grid while
  preserving its geometry.

- **Vector** (GeoJSON, GeoPackage, shapefile, ...): only a footprint is
  known, so a projected CRS is chosen for it and the grid is built
  exactly as
  [`grid_from_bbox()`](https://belian-earth.github.io/garry/reference/grid_from_bbox.md)
  does, honouring `projection`/`ellps`.

Remote sources are read via HTTP range requests (header only), so this
does not download the whole file.

## Examples

``` r
if (FALSE) { # \dontrun{
# Vector footprint -> equal-area 30 m grid.
target <- grid_from_src("catchment.gpkg", res = 30)
# Raster -> its own CRS/extent at 30 m.
g <- grid_from_src("s3://.../embedding.tif", res = 30)
} # }
```
