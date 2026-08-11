# All node ids in the graph, in ascending id order.

Ids are assigned sequentially by
[`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md)
and never reordered, so ascending id order is also insertion order.

## Usage

``` r
graph_ids(graph)
```

## Arguments

- graph:

  A `Graph`.

## Value

Integer vector of node ids, sorted ascending.

## See also

Other graph functions:
[`Graph()`](https://belian-earth.github.io/garry/reference/Graph.md),
[`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md),
[`graph_get()`](https://belian-earth.github.io/garry/reference/graph_get.md),
[`graph_import()`](https://belian-earth.github.io/garry/reference/graph_import.md),
[`graph_new()`](https://belian-earth.github.io/garry/reference/graph_new.md),
[`graph_replace()`](https://belian-earth.github.io/garry/reference/graph_replace.md),
[`graph_toposort()`](https://belian-earth.github.io/garry/reference/graph_toposort.md)
