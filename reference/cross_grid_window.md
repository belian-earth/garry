# Map an output-chunk window on `out_grid` to the minimal input window required on `in_grid`.

Same CRS: exact affine math (north-up grids, so window corners are
extremal). Different CRS: bounds are transformed with
[`gdalraster::transform_bounds()`](https://firelab.github.io/gdalraster/reference/transform_bounds.html),
which densifies the boundary so curved edges (e.g. parallels in a
transverse Mercator zone) cannot shrink the window; a safety margin of
`garry_opt("window_margin")` input cells is then added.

## Usage

``` r
cross_grid_window(
  out_grid,
  in_grid,
  x_off,
  y_off,
  x_size,
  y_size,
  margin = NULL
)
```

## Arguments

- out_grid, in_grid:

  `GridSpec`s of the consumer and producer.

- x_off, y_off, x_size, y_size:

  0-based output window on `out_grid`.

- margin:

  Safety margin in input cells; defaults to 0 for same-CRS windows and
  `garry_opt("window_margin")` across CRS.

## Value

A list with the 0-based input window.

## Details

Returns a list (x_off, y_off, x_size, y_size), 0-based, clipped to
`in_grid`. A window fully outside `in_grid` returns zero sizes.
