# Elementwise select: `yes` where `cond`, else `no`.

Elementwise select: `yes` where `cond`, else `no`.

## Usage

``` r
g_ifelse(cond, yes, no)
```

## Arguments

- cond:

  Logical array, or a stored 0/1 mask: nonzero is true.

- yes, no:

  Arrays or scalars, broadcast against `cond`.

## Value

Array shaped like `cond`.
