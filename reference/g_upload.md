# Upload an R array to an AnvlArray of the given garry dtype.

Unsigned dtypes upload via a wider signed carrier (see
`.anvl_upload_dtype`): anvl cannot construct them from R numerics.

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
