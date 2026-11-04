# Compute the output grid given this node and its parents' grids.

Part of the extension API for authors of new node classes; not needed
for ordinary use of the package. A source returns its own grid; map and
focal nodes return their first parent's grid; a stack adds its axis, a
scan may change the dtype, and warp, reduce and patch nodes change the
grid.

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
