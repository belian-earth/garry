# Combine inputs along a named dim (e.g. time). Created by [`lazy_stack()`](https://belian-earth.github.io/garry/reference/lazy_stack.md).

Combine inputs along a named dim (e.g. time). Created by
[`lazy_stack()`](https://belian-earth.github.io/garry/reference/lazy_stack.md).

## Usage

``` r
StackNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  role = character(0),
  along = character(0)
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

- along:

  Name of the dim to stack along.

## Value

A `StackNode`.
