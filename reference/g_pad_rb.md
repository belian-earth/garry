# Pad the bottom/right edges of the last two dims.

Grows the spatial dims by `(dy, dx)` cells of `value` on the high side
only: the shape-alignment pad (e.g. to a /32-divisible U-Net input) that
a later slice removes exactly.

## Usage

``` r
g_pad_rb(x, dy, dx, value = 0)
```

## Arguments

- x:

  Array of rank \>= 2 (traced or plain).

- dy, dx:

  Non-negative cell counts to add below / to the right.

- value:

  Fill value.

## Value

Array with the last two dims grown by `dy`, `dx`.
