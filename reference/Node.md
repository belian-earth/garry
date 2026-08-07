# Abstract IR node.

Abstract IR node.

## Usage

``` r
Node(id = integer(0), parents = integer(0), grid = GridSpec())
```

## Arguments

- id:

  Integer node id (assigned by
  [`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)).

- parents:

  Integer ids of parent nodes (may be empty).

- grid:

  Output `GridSpec` of this node.

## Value

A `Node` subclass instance.
