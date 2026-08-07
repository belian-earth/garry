# Transpose an array (general permutation).

`perm[i]` names the input axis that becomes output axis `i` (base R
[`aperm()`](https://rdrr.io/r/base/aperm.html) semantics); `NULL`
reverses the axes.

## Usage

``` r
g_transpose(x, perm = NULL)
```

## Arguments

- x:

  Array (traced or plain).

- perm:

  Integer permutation, or `NULL`.

## Value

Permuted array.
