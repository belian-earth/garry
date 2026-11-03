# Hand C memory to an AnvlArray with no copy.

`mem` holds `prod(dim)` elements of `dtype` in ROW-major element order,
aligned to 64 bytes. The array owns it from here: XLA reads those bytes
in place, and
[`g_delete()`](https://belian-earth.github.io/garry/reference/g_delete.md)
frees them with no gc. R's heap never holds them, so a read need not
wait for a collection to go. This needs a CPU: a CUDA device holds its
own copy, so its reads go through
[`g_upload_raw()`](https://belian-earth.github.io/garry/reference/g_upload_raw.md).

## Usage

``` r
g_adopt_raw(mem, bytes, release, dtype, dim)
```

## Arguments

- mem:

  External pointer to the memory, cleared on success. Its finalizer must
  do nothing on a null address.

- bytes:

  Size of `mem`.

- release:

  External pointer to the C function that frees `mem`. It can run on an
  XLA thread, so it must not touch R.

- dtype:

  garry dtype string (typically `"f32"`).

- dim:

  Integer dims, `[nr, nc]` or `[t, nr, nc]`.

## Value

An `AnvlArray` on the default device.
