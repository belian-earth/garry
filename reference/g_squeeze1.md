# Drop a leading unit axis.

The inverse of `g_expand(x, 1L, 1L)`: `(1, d...)` becomes `(d...)` (e.g.
a `g_slice_t` single-slice result back to its plane).

## Usage

``` r
g_squeeze1(x)
```

## Arguments

- x:

  Array with `dim(x)[1] == 1` (traced or plain).

## Value

Array of one lower rank.
