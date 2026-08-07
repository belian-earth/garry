# A chunk partition of a GridSpec.

A chunk partition of a GridSpec.

## Usage

``` r
ChunkGrid(
  grid = GridSpec(),
  chunk_dim = integer(0),
  block_dim = integer(0),
  halo = integer(0)
)
```

## Arguments

- grid:

  The `GridSpec` being partitioned.

- chunk_dim:

  Integer length 2: chunk size (cx, cy) in pixels.

- block_dim:

  Integer length 2: native GDAL block size, for snapping.

- halo:

  Single non-negative integer halo radius in pixels.

## Value

A `ChunkGrid`.
