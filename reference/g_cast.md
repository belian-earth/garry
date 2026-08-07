# Cast to a garry dtype (oracle: value semantics only).

Float targets keep double storage; integer targets truncate toward zero;
`pred` maps nonzero to TRUE.

## Usage

``` r
g_cast(x, dtype)
```

## Arguments

- x:

  Numeric array.

- dtype:

  Target dtype string.

## Value

Array with `dtype`'s value semantics.
