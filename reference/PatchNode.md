# Whole-window model op: fn over the raw padded chunk. Halo-consuming.

Created by
[`lazy_patch()`](https://belian-earth.github.io/garry/reference/lazy_patch.md).
The stencil shape for kernels whose spatial context is far beyond a
shift-list focal (CNN inference, e.g. OmniCloudMask): `fn(xpad)`
receives the parent's value carrying at least `radius` halo cells per
side (a `(C, H, W)` cube, traced or plain) and returns a SIZE-PRESERVING
result on the same spatial dims, deriving every size from the input
shape (chunk shapes vary); the evaluator crops the `radius` ring
afterwards, exactly as focal shifts consume theirs. Output rank: 2 when
`out_bands == 0` (the band axis is consumed), else 3 with a leading band
axis of length `out_bands`.

## Usage

``` r
PatchNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  role = character(0),
  fn = function() NULL,
  radius = integer(0),
  out_bands = integer(0),
  dtype = character(0),
  kernel_id = character(0),
  bytes_px = integer(0),
  flops_px = integer(0)
)
```

## Arguments

- id:

  Integer node id (assigned by
  [`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)).

- parents:

  Integer ids of parent nodes (length 1).

- grid:

  Output `GridSpec` of this node.

- role:

  Optional semantic role tag (e.g. "mask", set by
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md)).
  Pure metadata: never read by the planner or executors; surfaced by
  [`draw()`](https://belian-earth.github.io/garry/reference/draw.md) and
  [`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md).

- fn:

  The model body `fn(xpad)`.

- radius:

  Halo consumed per side, pixels.

- out_bands:

  Output band count; 0 drops the band axis.

- dtype:

  Length-0 (parent's dtype) or length-1 dtype override.

- kernel_id:

  Content hash standing in for `fn` in kernel signatures.

- bytes_px:

  Resident working-set estimate, bytes per core pixel.

- flops_px:

  Compute estimate, flops per core pixel.

## Value

A `PatchNode`.

## Details

`kernel_id` is the content identity of the closed-over model (weights

- configuration): it stands in for `fn` in kernel signatures, so `fn`
  itself is never serialised or hashed (a model closure can carry tens
  of MB). Two nodes with equal `kernel_id` are treated as the same
  kernel, so `kernel_id` must change whenever the model content changes.
  `bytes_px` / `flops_px` are planner cost hints per CORE pixel; they
  price chunk sizing, memory admission, and placement, which cannot
  introspect an arbitrary model closure.
