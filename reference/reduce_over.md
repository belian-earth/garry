# Reduction over named dims.

`op` is a reduction name (see `.reduce_ops`), not a function: the
planner needs op identity for algebraic decomposition (D12) and dtype
rules. `nan_rm = TRUE` (the default) skips nodata, matching R's
`na.rm = TRUE` under the NaN-sentinel model (D8).

## Usage

``` r
reduce_over(x, op, over, nan_rm = TRUE, bands = NULL)
```

## Arguments

- x:

  A `LazyRaster`, or a `LazyDataset`.

- op:

  Reduction name, e.g. `"mean"`, or a custom anvl reducer `fn(x, dims)`.

- over:

  Names of dims to reduce over (subset of `names(dims)`).

- nan_rm:

  Skip NaN (nodata) values?

- bands:

  `LazyDataset` only: bands to reduce (default: all bands).

## Value

A `LazyRaster` on the reduced grid, or a `LazyDataset` when given one.

## Details

Over a `LazyDataset`, each band is reduced independently (over `"t"`:
stack the band's slices and collapse time to a composite); `bands`
restricts which bands. `over = "band"` collapses the band axis,
returning a `LazyRaster`.
