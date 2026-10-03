# Focal (stencil) op. `radius` is the halo in pixels; `boundary` is "nodata", the only policy: cells beyond the raster edge are NaN. Created by [`focal_map()`](https://belian-earth.github.io/garry/reference/focal_map.md) and [`focal_kernel()`](https://belian-earth.github.io/garry/reference/focal_kernel.md).

Focal (stencil) op. `radius` is the halo in pixels; `boundary` is
"nodata", the only policy: cells beyond the raster edge are NaN. Created
by
[`focal_map()`](https://belian-earth.github.io/garry/reference/focal_map.md)
and
[`focal_kernel()`](https://belian-earth.github.io/garry/reference/focal_kernel.md).

## Usage

``` r
FocalNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  role = character(0),
  fn = function() NULL,
  radius = integer(0),
  boundary = character(0),
  weights = integer(0)
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
  [`apply_mask()`](https://belian-earth.github.io/garry/reference/apply_mask.md)).
  Pure metadata: never read by the planner or executors; surfaced by
  [`plan_draw()`](https://belian-earth.github.io/garry/reference/plan_draw.md)
  and
  [`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md).

- fn:

  Neighbourhood function (over the list of shifted arrays).

- radius:

  Halo radius in pixels.

- boundary:

  Boundary policy: `"nodata"`.

- weights:

  Optional linear kernel, flattened row-major over (dy, dx), length
  (2\*radius+1)^2. When present the op is the weighted sum and is
  differentiable wrt the weights.

## Value

A `FocalNode`.
