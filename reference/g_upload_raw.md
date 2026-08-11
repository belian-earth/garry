# Upload a raw byte payload to an AnvlArray.

`bytes` holds `prod(dim)` elements of `dtype` in ROW-major element
order: one memcpy to the device, no double conversion, and no XLA
relayout (row-major matches the default layout).

## Usage

``` r
g_upload_raw(bytes, dtype, dim, device = NULL)
```

## Arguments

- bytes:

  Raw vector (native little-endian payload).

- dtype:

  garry dtype string (typically `"f32"`).

- dim:

  Integer dims, `[nr, nc]` or `[t, nr, nc]`.

- device:

  Optional device (e.g. "cuda"); NULL uses the default.

## Value

An `AnvlArray`.
