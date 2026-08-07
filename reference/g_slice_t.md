# Static range slice along dim 1 (the scanned axis).

`x[from:to, ...]` keeping the leading axis: the building block for scan
bodies that pair a series with its own shift (e.g. an RTS smoother
reading the NEXT step's prediction).

## Usage

``` r
g_slice_t(x, from, to)
```

## Arguments

- x:

  Array with the scanned axis first.

- from, to:

  1-based static bounds (inclusive).

## Value

Array with dim 1 of length `to - from + 1`.
