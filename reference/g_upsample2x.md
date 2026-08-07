# Nearest-neighbour 2x upsample of a (C, H, W) chunk.

Each pixel becomes a 2x2 block (the U-Net decoder upsample).

## Usage

``` r
g_upsample2x(x)
```

## Arguments

- x:

  `(C, H, W)` array (traced or plain).

## Value

`(C, 2H, 2W)` array.
