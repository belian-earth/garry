# Compute the output grid given this node and its parents' grids.

Default: first parent's grid (elementwise, focal, stack). Ops that
change the grid override (Warp, Reduce).

## Usage

``` r
output_grid(node, ...)
```

## Arguments

- node:

  An IR `Node`.

- ...:

  Method arguments: `parent_grids`, a list of parent `GridSpec`s.

## Value

The node's output `GridSpec`.
