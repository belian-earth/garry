# Concatenate along dim 1 (the scanned axis).

Matrices are treated as single (1, y, x) slices, so a scan's stacked
buffers and a final plane concatenate directly.

## Usage

``` r
g_concat_t(xs)
```

## Arguments

- xs:

  List of arrays: (k, y, x) cubes and/or (y, x) matrices.

## Value

Array with dim 1 = total slice count.
