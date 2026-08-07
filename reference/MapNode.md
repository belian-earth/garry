# Elementwise map. `fn` is an R function over scalars/arrays; it will be composed with neighbouring fusable nodes and wrapped in `anvl::jit()` at plan time.

Elementwise map. `fn` is an R function over scalars/arrays; it will be
composed with neighbouring fusable nodes and wrapped in
[`anvl::jit()`](https://r-xla.github.io/anvl/reference/jit.html) at plan
time.

## Usage

``` r
MapNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  fn = function() NULL
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

- fn:

  Elementwise R function.

## Value

A `MapNode`.
