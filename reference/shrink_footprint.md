# Shrink the valid-data footprint by a pixel margin.

Sets to NaN every pixel within `radius` pixels of nodata, eroding each
nodata boundary (scene footprint edges, cloud-mask holes) by that
margin. The standard cure for corrupt scene edges: satellite granules
commonly carry one or two pixels of bad radiometry just inside their
data footprint that QA masks miss, and on a `(t, y, x)` stack each
slice's footprint erodes independently.

## Usage

``` r
shrink_footprint(x, radius = 1L, bands = NULL, boundary = c("nodata", "keep"))
```

## Arguments

- x:

  A `LazyRaster`, or a `LazyDataset`.

- radius:

  Margin to remove, in pixels.

- bands:

  `LazyDataset` only: bands to apply to (default: all value bands).

- boundary:

  What lies beyond the grid edge: `"nodata"` or `"keep"`.

## Value

The eroded object, same class and grid as `x`.

## Details

It is morphology on the nodata mask: the footprint erodes by `radius`
exactly as
[`apply_mask()`](https://belian-earth.github.io/garry/reference/apply_mask.md)'s
`dilate` grows a mask by `radius`.

`boundary` sets what lies beyond the edge of the grid. `"nodata"` (the
default) treats it as nodata, so the grid's own border erodes too.
`"keep"` treats it as valid, so only real nodata edges erode and the
result keeps its full extent; use it when the data continues past the
analysis grid. `"keep"` applies to 2-D rasters (`(y, x)`); over a
`LazyDataset` it applies slice by slice.

Implemented with focal stencils, so it plans and fuses like any
[`focal_map()`](https://belian-earth.github.io/garry/reference/focal_map.md),
and applies per band over a `LazyDataset`.
