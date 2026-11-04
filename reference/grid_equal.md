# Structural equality of two grids (geometry only, not dtype).

Transforms and extents match to within 1e-9 in the CRS's units; dtype
and axis labels are ignored.

## Usage

``` r
grid_equal(a, b)
```

## Arguments

- a, b:

  `GridSpec` objects.

## Value

`TRUE` or `FALSE`.

## See also

[`grid_diff()`](https://belian-earth.github.io/garry/reference/grid_diff.md),
which describes how two grids differ.
