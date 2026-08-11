# Compute the output grid given this node and its parents' grids.

Part of the extension API for authors of new node classes; not needed
for ordinary use of the package. Default: first parent's grid
(elementwise, focal, stack). Ops that change the grid override (Warp,
Reduce).

## Usage

``` r
output_grid(node, ...)
```

## Arguments

- node:

  An intermediate representation (IR) `Node`.

- ...:

  Method arguments: `parent_grids`, a list of parent `GridSpec`s.

## Value

The node's output `GridSpec`.
