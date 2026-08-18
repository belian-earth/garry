# Scan along a named dim, preserving it. Barrier over `over`.

Created by
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md).
The IR shape between `MapNode` and `ReduceNode`: carry state
sequentially along one non-spatial axis while emitting a same-length
series (Kalman smoothers, EWMA, IIR filters, cumulative ops). The output
grid is the parent grid unchanged (the scanned axis survives),
optionally with a dtype override.

## Usage

``` r
ScanNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  role = character(0),
  over = character(0),
  direction = character(0),
  fn = list(),
  dtype = character(0)
)
```

## Arguments

- id:

  Integer node id (assigned by
  [`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)).

- parents:

  Integer ids of parent nodes.

- grid:

  Output `GridSpec` of this node.

- role:

  Optional semantic role tag (e.g. "mask", set by
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md)).
  Pure metadata: never read by the planner or executors; surfaced by
  [`draw()`](https://belian-earth.github.io/garry/reference/draw.md) and
  [`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md).

- over:

  Single dim name to scan along (`"t"` or `"band"`).

- direction:

  One of `"forward"`, `"backward"`, `"bidir"`.

- fn:

  Length-1 list holding the scan body `fn(xs, margin)`.

- dtype:

  Length-0 (parent's dtype) or length-1 dtype override.

## Value

A `ScanNode`.

## Details

The body kernel is `fn(xs, margin) -> y`: `xs` is the LIST of parent
chunk values (length \>= 1; multi-parent scans read several cubes in
lockstep), `margin` is the 1-based position of the scanned axis in the
chunk's dimension order (outer dims first, then y, x), and `y` has the
same shape as `xs[[1]]`. Inside, the body uses
[`g_scan()`](https://belian-earth.github.io/garry/reference/g_scan.md)
to carry state along `margin`; everything else in the chunk (the spatial
axes) is batched through the carry. Like a custom reducer, a scan cannot
be decomposed across spatial chunks, so it is supported over `t`/`band`
only (each spatial chunk holds the full axis).

`direction` is declarative metadata (drawn, hashed into the kernel
signature): `"bidir"` bodies run a forward and a reverse
[`g_scan()`](https://belian-earth.github.io/garry/reference/g_scan.md)
internally as ONE fused kernel, so forward state never crosses a node
boundary.
