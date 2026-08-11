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

## See also

Other graph functions:
[`Graph()`](https://belian-earth.github.io/garry/reference/Graph.md),
[`graph_get()`](https://belian-earth.github.io/garry/reference/graph_get.md),
[`graph_ids()`](https://belian-earth.github.io/garry/reference/graph_ids.md),
[`graph_import()`](https://belian-earth.github.io/garry/reference/graph_import.md),
[`graph_new()`](https://belian-earth.github.io/garry/reference/graph_new.md),
[`graph_replace()`](https://belian-earth.github.io/garry/reference/graph_replace.md),
[`graph_toposort()`](https://belian-earth.github.io/garry/reference/graph_toposort.md)
