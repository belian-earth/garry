# Reduction over named dims. Barrier: forces materialisation of its inputs.

`op` is normally a name from `.reduce_ops`: the planner needs op
identity to decide algebraic decomposition (D12) and output dtype, and
the executor maps it to the ops vocabulary. A CUSTOM reducer may instead
be supplied as `fn` (a length-1 list holding an anvl function
`fn(x, dims)` that collapses `dims`), with `op = "custom"`; the executor
calls it directly. A custom reducer cannot be decomposed across spatial
chunks, so it is supported over the `t`/`band` axes (each spatial chunk
holds the full axis), not over `x`/`y`.

## Usage

``` r
ReduceNode(
  id = integer(0),
  parents = integer(0),
  grid = GridSpec(),
  op = character(0),
  over = character(0),
  nan_rm = logical(0),
  fn = list()
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

- op:

  Reduction name, e.g. "mean" (see `.reduce_ops`), or "custom".

- over:

  Names of dims to reduce over.

- nan_rm:

  Skip NaN (nodata) values? (Named ops only; a custom `fn` handles NaN
  itself.)

- fn:

  Length-0 (named op) or length-1 list holding a custom anvl reducer
  `fn(x, dims)`.

## Value

A `ReduceNode`.
