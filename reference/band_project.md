# A band reducer for a linear combination of bands.

Returns an anvl reducer `fn(x, dims)` for
`reduce_over(cube, fn, over = "band")`: it centres each band (optional)
and forms the weighted sum `sum_b weights[b] * (band_b - center[b])` per
pixel – a linear projection of the band vector. This is the "reduce over
bands" primitive behind spectral indices, linear/logistic prediction,
and PCA. For multiple outputs (e.g. the first `k` principal components)
build one reducer per weight column and stack:

## Usage

``` r
band_project(weights, center = NULL)
```

## Arguments

- weights:

  Per-band coefficients (length = number of bands).

- center:

  Optional per-band centre subtracted before weighting (e.g. a PCA's
  column means); length must match `weights`.

## Value

A function `fn(x, dims)` suitable for
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
`over = "band"`.

## Details

    pc <- lapply(1:3, \(i) reduce_over(cube, band_project(rot[, i], centre),
                                       over = "band"))
    collect(lazy_stack(pc, along = "band"))            # (3, y, x)
