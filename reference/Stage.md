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

  The composed stage closure (see calling conventions).

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

  Spatial padding the stage's chunks are computed with (D22): consumers
  needing a halo on this stage's exports receive it as a recomputed ring
  instead of a materialise-first refusal. Inputs arrive padded to
  `halo + out_pad`.

- export_pads:

  Integer vector parallel to `exports`: the padding each export value
  carries (post-focal exports carry less than pre-focal ones). Empty
  means all zero.

## Value

A `Stage`.
