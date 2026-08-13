# Round to nearest integer value (half to even), elementwise.

Matches base R's `round(x)` semantics (IEEE round-half-to-even), so
device-side quantization reproduces the historical writer-side
[`round()`](https://rdrr.io/r/base/Round.html) exactly.

## Usage

``` r
g_round(x)
```

## Arguments

- x:

  Traced array or plain numeric.

## Value

Same shape as `x`.
