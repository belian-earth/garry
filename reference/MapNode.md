# Elementwise map. `fn` is an R function over scalars/arrays; it will be composed with neighbouring fusable nodes and wrapped in `anvl::jit()` at plan time. Created by [`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md).

Elementwise map. `fn` is an R function over scalars/arrays; it will be
composed with neighbouring fusable nodes and wrapped in
[`anvl::jit()`](https://r-xla.github.io/anvl/reference/jit.html) at plan
time. Created by
[`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md).

## Usage

``` r
MapNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  role = character(0),
  fn = function() NULL,
  dtype = character(0)
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

  Elementwise R function.

- dtype:

  Length-0 (the dtype `fn` was traced to return) or length-1 dtype named
  by the caller of
  [`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md).

## Value

A `MapNode`.
