# Grid extent and resolution accessors.

Grid extent and resolution accessors.

## Usage

``` r
xmin(x, ...)

ymin(x, ...)

xmax(x, ...)

ymax(x, ...)

res(x, ...)
```

## Arguments

- x:

  A `GridSpec` or a `LazyRaster` (which forwards to its grid).

- ...:

  Passed to methods.

## Value

A numeric scalar (`xmin`, `ymin`, `xmax`, `ymax`) or a length-2 numeric
`c(xres, yres)` for `res`.
