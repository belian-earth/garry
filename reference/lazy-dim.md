# Dimensions of a lazy raster

The shape
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
returns: rows (`y`), columns (`x`), then any non-spatial axes (`t`,
`band`), named.

## Arguments

- x:

  A `LazyRaster` or `GridSpec`.

## Value

A named integer vector.

## Examples

``` r
g <- grid_spec(c(0, 0, 100, 50), res = 10, crs = "EPSG:3857")
dim(g)
#>  y  x 
#>  5 10 
```
