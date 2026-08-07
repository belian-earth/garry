# Stack aligned rasters along a new outer dim (default time).

All layers must share the spatial grid (align first otherwise); dtypes
promote to a common type. Chunks carry the stack as (t, y, x) arrays
(decision D17); temporal reductions (`reduce_over(x, "median", "t")`)
then run chunk-locally.

## Usage

``` r
lazy_stack(xs, along = "t")
```

## Arguments

- xs:

  List of `LazyRaster`s on one grid.

- along:

  Name of the new dim ("t" or "band").

## Value

A `LazyRaster` with an extra dim.
