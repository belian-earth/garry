# Reductions over array margins (pure-R oracle semantics).

Reductions over array margins (pure-R oracle semantics).

## Usage

``` r
g_sum(x, dims = NULL, nan_rm = FALSE)

g_mean(x, dims = NULL, nan_rm = FALSE)

g_min(x, dims = NULL, nan_rm = FALSE)

g_max(x, dims = NULL, nan_rm = FALSE)

g_median(x, dims = NULL, nan_rm = FALSE)

g_count(x, dims = NULL)
```

## Arguments

- x:

  Numeric array.

- dims:

  Integer margins to reduce, or NULL for all.

- nan_rm:

  Skip NaN (nodata)?

## Value

Reduced array (margins in `dims` dropped) or scalar.
