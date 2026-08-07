# Scan along an axis, keeping it (temporal recursions).

The length-preserving sibling of
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md):
carry state sequentially along `over` while emitting a same-length
series (Kalman smoothers, EWMA, IIR filters, cumulative custom ops). The
output grid is the input grid unchanged; only the dtype may differ.

## Usage

``` r
scan_over(x, fn, over = "t", direction = "forward", dtype = NULL, bands = NULL)
```

## Arguments

- x:

  A `LazyRaster`, a list of `LazyRaster`s on the same graph and grid
  (multi-input scan), or a `LazyDataset`.

- fn:

  Scan body `fn(xs, margin)`.

- over:

  Single dim name to scan along (default `"t"`).

- direction:

  `"forward"`, `"backward"`, or `"bidir"` (the body encapsulates
  direction; this is declarative metadata).

- dtype:

  Optional output dtype override (default: input dtype).

- bands:

  `LazyDataset` only: bands to scan (default: all).

## Value

A `LazyRaster` on the unchanged grid, or a `LazyDataset`.

## Details

`fn` is the scan body `fn(xs, margin) -> y`, written in the `g_*`
vocabulary and typically built around
[`g_scan()`](https://belian-earth.github.io/garry/reference/g_scan.md):
`xs` is the LIST of parent chunk values (pass a list of LazyRasters on
the same grid to scan several cubes in lockstep), `margin` is the
scanned axis position, and `y` has the shape of `xs[[1]]`. Like a custom
reducer, a scan holds the full `over` axis per spatial chunk, so it is
supported over `"t"`/`"band"` only.

Over a `LazyDataset`, each band's slices are stacked along `"t"` and
scanned independently (`bands` restricts which).
