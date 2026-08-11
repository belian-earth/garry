# Compute graph.

The container for garry's IR nodes.
[`graph_new()`](https://belian-earth.github.io/garry/reference/graph_new.md)
is the constructor; nodes are added with
[`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md).

## Usage

``` r
Graph(nodes = new.env(parent = emptyenv()))
```

## Arguments

- nodes:

  Environment holding the node table and id counter.

## Value

A `Graph`.

## See also

Other graph functions:
[`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md),
[`graph_get()`](https://belian-earth.github.io/garry/reference/graph_get.md),
[`graph_ids()`](https://belian-earth.github.io/garry/reference/graph_ids.md),
[`graph_import()`](https://belian-earth.github.io/garry/reference/graph_import.md),
[`graph_new()`](https://belian-earth.github.io/garry/reference/graph_new.md),
[`graph_replace()`](https://belian-earth.github.io/garry/reference/graph_replace.md),
[`graph_toposort()`](https://belian-earth.github.io/garry/reference/graph_toposort.md)
