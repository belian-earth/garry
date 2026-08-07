# Shrink the valid-data footprint by a pixel margin.

Sets to NaN every pixel within `radius` pixels of nodata, eroding each
nodata boundary (scene footprint edges, cloud-mask holes, the raster
border) by that margin. The standard cure for corrupt scene edges:
satellite granules commonly carry one or two pixels of bad radiometry
just inside their data footprint that QA masks miss, and on a
`(t, y, x)` stack each slice's footprint erodes independently.

## Usage

``` r
shrink_footprint(x, radius = 1L, bands = NULL)
```

## Arguments

- x:

  A `LazyRaster`, or a `LazyDataset`.

- radius:

  Margin to remove, in pixels.

- bands:

  `LazyDataset` only: bands to apply to (default: all value bands).

## Value

The eroded object, same class and grid as `x`.

## Details

Implemented as a
[`focal()`](https://belian-earth.github.io/garry/reference/focal.md)
kernel (centre plus zero times the window sum, which is NaN wherever any
neighbour is NaN), so it plans and fuses like any stencil, and applies
per band over a `LazyDataset`.
