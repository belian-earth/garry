# Stack same-shaped arrays along a new leading axis.

`(y, x)` matrices stack into a `(t, y, x)` cube; `(t, y, x)` cubes stack
into a `(k, t, y, x)` hyper-cube (e.g. a rolling window's shifted
copies, reduced over dim 1).

## Usage

``` r
g_stack(values)
```

## Arguments

- values:

  List of same-shaped arrays.

## Value

A `length(values) x dim(values[[1]])` array.
