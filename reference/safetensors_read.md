# Read tensors from a safetensors file.

Returns a named list of R arrays indexed exactly like the source torch
tensors (`x[i, j, ...]` agrees elementwise): the row-major payload is
reshaped through the reversed dims and `aperm`ed back. F32 tensors only;
others (e.g. I64 `num_batches_tracked`) are silently dropped. A 0-d
tensor becomes a length-1 vector.

## Usage

``` r
safetensors_read(path, names = NULL)
```

## Arguments

- path:

  Path to a `.safetensors` file.

- names:

  Optional character vector restricting which tensors to read (default:
  all F32 tensors).

## Value

Named list of numeric arrays.
