# Elementwise select: `yes` where `cond`, else `no`.

Elementwise select: `yes` where `cond`, else `no`.

## Usage

``` r
g_ifelse(cond, yes, no)
```

## Arguments

- cond:

  Logical array.

- yes, no:

  Arrays or scalars, broadcast against `cond`.

## Value

Array shaped like `cond`.
