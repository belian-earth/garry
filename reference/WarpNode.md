# Lazy resample/reproject to a target grid. Created by [`align()`](https://belian-earth.github.io/garry/reference/align.md). Barrier. At execution time this materialises as a gdalraster VRT warp.

Lazy resample/reproject to a target grid. Created by
[`align()`](https://belian-earth.github.io/garry/reference/align.md).
Barrier. At execution time this materialises as a gdalraster VRT warp.

## Usage

``` r
WarpNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  role = character(0),
  target_grid = GridSpec(),
  resampling = character(0)
)
```

## Arguments

- id:

  Integer node id (assigned by
  [`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)).

- parents:

  Integer ids of parent nodes (may be empty).

- grid:

  Output `GridSpec` of this node.

- role:

  Optional semantic role tag (e.g. "mask", set by
  [`mask()`](https://belian-earth.github.io/garry/reference/mask.md)).
  Pure metadata: never read by the planner or executors; surfaced by
  [`draw()`](https://belian-earth.github.io/garry/reference/draw.md) and
  [`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md).

- target_grid:

  `GridSpec` to warp onto.

- resampling:

  Resampling method ("nearest", "bilinear", "cubic", ...).

## Value

A `WarpNode`.
