# Linear focal op with an explicit kernel (differentiable).

The kernel is a (2r+1) x (2r+1) matrix of weights; the op is the
weighted sum over the window. Unlike
[`focal_map()`](https://belian-earth.github.io/garry/reference/focal_map.md)
with an arbitrary `fn`, a kernel focal is differentiable with respect to
its weights: pass the returned LazyRaster as `wrt` to
[`lazy_value_and_grad()`](https://belian-earth.github.io/garry/reference/lazy_value_and_grad.md).

## Usage

``` r
focal_kernel(x, weights)
```

## Arguments

- x:

  A `LazyRaster`.

- weights:

  Square odd-sided numeric matrix, rows = dy, cols = dx.

## Value

A `LazyRaster` (a float for an integer `x`, which is read as the float
that holds it so cells beyond the raster edge can be NaN).
