# Cast to a garry dtype.

Integer targets truncate toward zero; `pred` maps nonzero to TRUE. On
plain R arrays the cast changes value semantics only (storage stays
double).

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
