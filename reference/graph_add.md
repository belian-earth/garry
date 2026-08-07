# Add a node. `ctor` is an S7 node constructor; `...` are its properties (the `id` property is assigned here and passed automatically).

Add a node. `ctor` is an S7 node constructor; `...` are its properties
(the `id` property is assigned here and passed automatically).

## Usage

``` r
graph_add(graph, ctor, ...)
```

## Arguments

- graph:

  A `Graph`.

- ctor:

  S7 node class constructor.

- ...:

  Properties passed to `ctor`.

## Value

The assigned integer id.
