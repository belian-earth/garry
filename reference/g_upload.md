# Upload an R array to an AnvlArray of the given garry dtype.

`u8`, `u16` and `u32` upload as `i16`, `i32` and `i64`, and `u64` as
`f64`. An integer buffer holds no NaN, so a missing value in `x` aborts
with a `garry_nodata_error` when the upload dtype is an integer.

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
