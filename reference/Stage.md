# One schedulable unit of a Plan.

One schedulable unit of a Plan.

## Usage

``` r
Stage(
  id = integer(0),
  kind = character(0),
  members = integer(0),
  fn = function() NULL,
  halo = integer(0),
  grid = GridSpec(),
  chunks = ChunkGrid(),
  device = character(0),
  inputs = integer(0),
  input_nodes = integer(0),
  exports = integer(0),
  out_pad = 0L,
  export_pads = integer(0)
)
```

## Arguments

- id:

  Stage id (dense, 1-based).

- kind:

  One of "source_read", "compute", "reduce_partial", "reduce_combine",
  "warp".

- members:

  IR node ids composed into this stage (ascending = topo).

- fn:

  The composed stage closure. For "compute" stages it is called as
  `fn(inputs)` with a list of chunk arrays in `input_nodes` order, each
  padded to the stage halo, and returns the chunk-core array; a
  "reduce_partial" stage returns a named list of per-chunk partials and
  "reduce_combine" combines those lists into the final value; for
  "source_read" and "warp" stages `fn` is the identity (the executor and
  the GDAL warper supply the values).

- halo:

  Halo radius in pixels the stage requires on its inputs.

- grid:

  Output `GridSpec` of the stage.

- chunks:

  `ChunkGrid` partitioning the stage's output.

- device:

  Device tag ("cpu" or "cuda").

- inputs:

  Stage ids feeding this stage.

- input_nodes:

  IR node ids whose values `fn` receives, in order.

- exports:

  Member node ids `fn` returns, ascending (consumed by other stages,
  plus the stage tail).

- out_pad:

  Spatial padding rings the stage's chunks are computed with: consumers
  needing a halo on this stage's exports receive it as a ring of
  recomputed cells rather than requiring the stage to materialise first.
  Inputs arrive padded to `halo + out_pad`.

- export_pads:

  Integer vector parallel to `exports`: the padding each export value
  carries (post-focal exports carry less than pre-focal ones). Empty
  means all zero.

## Value

A `Stage`.
