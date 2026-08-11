# Shifted slice of a padded matrix (the stencil building block).

Given `xpad = g_pad(x, h)`, returns the view of `x`'s shape offset by
(`dy`, `dx`) pixels, `dy`/`dx` in `[-h, h]`. Rows are y, columns are x.

## Usage

``` r
g_shift_slice(xpad, dy, dx, out_nrow, out_ncol, h)
```

## Arguments

- xpad:

  Padded matrix.

- dy, dx:

  Integer offsets in pixels.

- out_nrow, out_ncol:

  Dimensions of the unpadded matrix.

- h:

  Pad width used to build `xpad`.

## Value

An `out_nrow x out_ncol` matrix.
