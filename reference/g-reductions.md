# Reductions over array margins.

`g_sum` accumulates 8- and 16-bit integers in i32 (32-bit unsigned in
i64), so a sum does not wrap at the input type's range.

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

## Details

With `nan_rm = TRUE`, a slice that is entirely NaN reduces to the
reduction's identity value: `g_sum` gives 0, `g_min` gives `Inf`,
`g_max` gives `-Inf`, and `g_mean` / `g_median` give NaN. `g_count`
counts non-NaN values, so an all-NaN slice gives 0.
