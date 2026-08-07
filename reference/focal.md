# Focal (stencil) op.

`fn` receives a LIST of (2r+1)^2 shifted arrays, row-major over (dy, dx)
offsets, and returns one array: the whole neighbourhood is processed
vectorised across every pixel at once. This convention is what lets the
same closure run under the pure-R oracle and under anvl's jit()
(D10/D14). Example, a 3x3 sum: `function(sh) Reduce("+", sh)`.

## Usage

``` r
focal(x, fn, radius, boundary = "nodata", bands = NULL)
```

## Arguments

- x:

  LazyRaster, or a `LazyDataset`.

- fn:

  Function over the list of shifted arrays (see above).

- radius:

  Halo in pixels (mandatory: the footprint cannot be inferred from `fn`;
  decision D14).

- boundary:

  Boundary policy; only "nodata" in v1.

- bands:

  `LazyDataset` only: bands to apply to (default: all value bands).

## Details

Cells beyond the raster edge are NaN (nodata) — v1 supports only this
`boundary = "nodata"` policy; reflect/wrap remain unimplemented
(deliberately deferred, not scheduled).

Over a `LazyDataset`, the stencil is applied to every value band per
slice; `bands` restricts which bands.
