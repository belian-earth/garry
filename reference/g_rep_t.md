# Replicate a (y, x) plane along a new leading axis.

The broadcast helper for per-pixel statistics against a (t, y, x) cube
(e.g. a per-pixel MAD over the scanned axis reused at every t).

## Usage

``` r
g_rep_t(x, n)
```

## Arguments

- x:

  A (y, x) matrix (traced or plain).

- n:

  Number of leading-axis copies.

## Value

An (n, y, x) array.
