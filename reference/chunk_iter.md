# Enumerate chunks.

Returns a data frame of (ix, iy, x_off, y_off, x_size, y_size, shape_id)
for every chunk. Offsets are 0-based. Sizes are clipped at the grid
edge: edge chunks are smaller, never padded to a uniform size.
`shape_id` classifies each chunk as "interior", "right", "bottom", or
"corner"; a regular chunk grid produces at most these four distinct
shapes.

## Usage

``` r
chunk_iter(cg, ...)
```

## Arguments

- cg:

  A `ChunkGrid`.

- ...:

  Passed to methods.

## Value

A data frame with one row per chunk.
