# Bitwise operations on integral arrays.

Bitwise operations on integral arrays.

## Usage

``` r
g_bitand(a, b)

g_bitor(a, b)

g_bitxor(a, b)

g_bitnot(a)

g_shiftl(a, n)

g_shiftr(a, n)
```

## Arguments

- a, b:

  Integral arrays (or scalar `b`); recycled like base R.

- n:

  Shift amount in bits.

## Value

Integral array shaped like `a`.

## See also

[`qa_bits()`](https://belian-earth.github.io/garry/reference/qa_bits.md)
and
[`apply_mask()`](https://belian-earth.github.io/garry/reference/apply_mask.md)
for the QA-masking verbs built on these ops.
