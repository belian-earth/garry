# Enumerate chunks.

Returns a data frame of (ix, iy, x_off, y_off, x_size, y_size, shape_id)
for every chunk. Offsets are 0-based. Sizes are clipped at the grid
edge. `shape_id` classifies each chunk as "interior", "right", "bottom",
or "corner" — a regular chunk grid produces at most these four distinct
shapes (decision D4: no pad-to-uniform; the executor's kernel cache sees
\<= 4 shapes per stage).

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
