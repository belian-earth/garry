# Value and gradient of a scalar LazyRaster loss wrt a focal kernel.

`loss` must be a scalar pipeline (global `sum` or `mean` reduction)
containing `wrt`, a
[`focal_kernel()`](https://belian-earth.github.io/garry/reference/focal_kernel.md)
raster whose weights are the parameters. Executes chunk by chunk
(gradients compose by linearity) with the mask-multiply nodata rewrite
(D15).

## Usage

``` r
lazy_value_and_grad(loss, wrt, weights = NULL)
```

## Arguments

- loss:

  Scalar `LazyRaster` (reduced over x and y).

- wrt:

  The
  [`focal_kernel()`](https://belian-earth.github.io/garry/reference/focal_kernel.md)
  LazyRaster to differentiate against.

- weights:

  Optional kernel matrix overriding the weights stored in `wrt` (used by
  optimisation loops to avoid rebuilding graphs).

## Value

`list(value = <scalar>, grad = <kernel-shaped matrix>)`.
