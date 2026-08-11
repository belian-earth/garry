# Build an analysis grid from a lon/lat bounding box.

Picks a projected CRS for the area of interest (centred on the bbox),
reprojects the extent into it, snaps the extent out to whole multiples
of `res`, and returns a ready `GridSpec`.

## Usage

``` r
grid_from_bbox(
  bbox,
  res,
  projection = c("laea", "aeqd", "utm", "pconic", "eqdc"),
  ellps = "WGS84",
  buffer = 0,
  dtype = "f32"
)
```

## Arguments

- bbox:

  Length-4 numeric lon/lat bbox (xmin, ymin, xmax, ymax), EPSG:4326.

- res:

  Target resolution in the projected CRS units (metres for the supported
  projections); a scalar, or `c(xres, yres)`.

- projection:

  Projection family; the first is the default (see Details).

- ellps:

  Ellipsoid for the centred projections.

- buffer:

  Extent padding in projected units, applied before snapping.

- dtype:

  Grid dtype.

## Value

A `GridSpec`.

## Details

The default projection is Lambert azimuthal equal-area (`"laea"`)
centred on the AOI: analysis wants an equal-area basis, so areas,
fractions and densities are correct and there are no zone seams. `"utm"`
is available when you want storage-oriented zone alignment (it is not
equal-area). `"aeqd"` is azimuthal equidistant (true distances from the
centre); `"pconic"`/`"eqdc"` are conics using the bbox's north/south
edges as standard parallels. Centred projections are bespoke (no EPSG
code), so a grid's CRS may print as its projection name rather than an
EPSG code.

## See also

[`grid_from_src()`](https://belian-earth.github.io/garry/reference/grid_from_src.md)
to build a grid from a raster or vector source;
[`grid_spec()`](https://belian-earth.github.io/garry/reference/grid_spec.md)
to build one from an explicit extent.

## Examples

``` r
# An equal-area 30 m grid over a small AOI.
g <- grid_from_bbox(c(144.13, -7.725, 144.47, -7.475), res = 30)
```
