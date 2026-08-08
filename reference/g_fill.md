# Construct a constant-filled AnvlArray on the device.

The fill is represented in the program (no host buffer of `prod(dim)`
elements is built or transferred), so it is the cheap way to make a
large device array — e.g. warm-up dummies for kernel precompiles.

## Usage

``` r
g_fill(value, dim, dtype = "f32", device = NULL)
```

## Arguments

- value:

  Scalar fill value.

- dim:

  Integer dims, `[nr, nc]` or `[t, nr, nc]`.

- dtype:

  garry dtype string (default `"f32"`).

- device:

  Optional device (e.g. "cuda"); NULL uses the default.

## Value

An `AnvlArray`.
