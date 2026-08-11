# Import the subgraph reachable from `root_id` in `src` into `dst`.

Node ids are renumbered; a SourceNode identical in (path, band, nodata,
grid, dtype) to one already in `dst` is deduplicated. Graphs are
append-only (rewrites swap nodes in place, ids never reorder), so
ascending id order within the reachable set is a valid topological
order.

## Usage

``` r
graph_import(dst, src, root_id)
```

## Arguments

- dst:

  Destination `Graph` (modified by reference).

- src:

  Source `Graph`.

- root_id:

  Id in `src` whose ancestry is imported.

## Value

The id of the imported root in `dst`.

## See also

Other graph functions:
[`Graph()`](https://belian-earth.github.io/garry/reference/Graph.md),
[`graph_add()`](https://belian-earth.github.io/garry/reference/graph_add.md),
[`graph_get()`](https://belian-earth.github.io/garry/reference/graph_get.md),
[`graph_ids()`](https://belian-earth.github.io/garry/reference/graph_ids.md),
[`graph_new()`](https://belian-earth.github.io/garry/reference/graph_new.md),
[`graph_replace()`](https://belian-earth.github.io/garry/reference/graph_replace.md),
[`graph_toposort()`](https://belian-earth.github.io/garry/reference/graph_toposort.md)
