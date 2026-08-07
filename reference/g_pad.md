# Pad a matrix by `h` cells on every side with `value`.

Pad a matrix by `h` cells on every side with `value`.

## Usage

``` r
g_pad(x, h, value = 0)
```

## Arguments

- x:

  A matrix.

- h:

  Non-negative integer pad width.

- value:

  Fill value (default 0).

## Value

A `(nrow + 2h) x (ncol + 2h)` matrix.
