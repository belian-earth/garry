# Upload an R array to an AnvlArray of the given garry dtype.

Unsigned dtypes upload via a wider signed carrier.

## Usage

``` r
g_upload(x, dtype, device = NULL)
```

## Arguments

- x:

  R array/matrix.

- dtype:

  garry dtype string (anvl-aligned).

- device:

  Optional device (e.g. "cuda"); NULL uses the default.

## Value

An `AnvlArray`.
