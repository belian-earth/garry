# Scan: carry state along dim 1, emitting per-step outputs.

The loop op behind
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md)
bodies (Kalman smoothers, EWMA, IIR filters, cumulative custom ops). At
step `t`, `body(carry, x)` gets the current carry and the step-`t` slice
of `xs` (taken along dim 1 with that unit axis dropped) and returns
`list(carry = , out = )`; the `out`s are stacked into `(length, ...)`
buffers. `reverse = TRUE` runs `t = length..1`, still reading and
writing at position `t` (what a backward smoothing pass needs, e.g.
Rauch-Tung-Striebel). Traced values route to
[`anvl::nv_scan`](https://r-xla.github.io/anvl/reference/nv_scan.html);
plain R arrays take the pure-R reference implementation with identical
semantics.

## Usage

``` r
g_scan(init, body, xs = NULL, length = NULL, reverse = FALSE)
```

## Arguments

- init:

  Initial carry: array or (nested) named list of arrays.

- body:

  Step function `function(carry, x) -> list(carry, out)`; `out` may be
  an array, a (nested) list, or `NULL`.

- xs:

  Per-step inputs sliced along dim 1 (array, nested list, or NULL).

- length:

  Static trip count; required when `xs` is NULL.

- reverse:

  Run steps in reverse order?

## Value

`list(carry = final carry, out = stacked outputs)`.

## Details

The scanned axis must be dim 1 of every `xs` leaf (garry's canonical
layout puts the scanned non-spatial axis first); bodies scanning a
non-leading margin must permute first.
