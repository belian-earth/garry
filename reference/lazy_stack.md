# Stack aligned rasters along a new outer dim (default time).

All layers must share the spatial grid
([`align()`](https://belian-earth.github.io/garry/reference/align.md)
first otherwise); dtypes promote to a common type. Chunks carry the
stack as (t, y, x) arrays; temporal reductions
(`reduce_over(x, "median", "t")`) then run chunk-locally.

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

## Details

Element names of `xs` become labels on the new axis (slice dates on `t`,
band names on `band`), used by
[`time_sel()`](https://belian-earth.github.io/garry/reference/time_sel.md)
/
[`band_sel()`](https://belian-earth.github.io/garry/reference/band_sel.md)
for label selection; an unnamed list leaves the axis unlabelled.
