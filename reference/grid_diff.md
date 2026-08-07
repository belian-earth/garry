# Describe how two grids differ.

The diagnostic companion to
[`grid_equal()`](https://belian-earth.github.io/garry/reference/grid_equal.md):
names the FIRST differing component (CRS, resolution, extent offset in
pixels, dims) so a "grids differ" abort tells the user what to fix
rather than only that something is wrong. Embedded in every alignment
error.

## Usage

``` r
grid_diff(a, b, tol = 1e-09)
```

## Arguments

- a, b:

  `GridSpec` objects.

- tol:

  Numeric tolerance, as in
  [`grid_equal()`](https://belian-earth.github.io/garry/reference/grid_equal.md).

## Value

A single character description; `"grids are equal"` when
[`grid_equal()`](https://belian-earth.github.io/garry/reference/grid_equal.md)
holds.
