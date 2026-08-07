# Expand a chunk window by the ChunkGrid's halo, clipped to the grid.

Returns a list with the padded window (`x_off`, `y_off`, `x_size`,
`y_size`) and the per-side pad actually applied (`pad_left`, `pad_top`,
`pad_right`, `pad_bottom`). Kernels trim by these values to recover the
unpadded output.

## Usage

``` r
chunk_window_with_halo(cg, ...)
```

## Arguments

- cg:

  A `ChunkGrid`.

- ...:

  Method arguments: `x_off`, `y_off`, `x_size`, `y_size`, the 0-based
  unpadded chunk window.

## Value

A list with the padded window and per-side pads.
