# Structural equality of two grids (geometry only, not dtype).

Structural equality of two grids (geometry only, not dtype).

## Usage

``` r
grid_equal(a, b, tol = 1e-09)
```

## Arguments

- a, b:

  `GridSpec` objects.

- tol:

  Numeric tolerance for transform/extent comparison.

## Value

`TRUE` or `FALSE`.

## See also

[`grid_diff()`](https://belian-earth.github.io/garry/reference/grid_diff.md),
which describes how two grids differ.
