# Read tensors from a safetensors file.

safetensors (<https://github.com/huggingface/safetensors>) is the simple
tensor serialisation format used across the machine-learning ecosystem,
typically for model weights.

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

## Details

Returns a named list of R arrays indexed exactly like the source torch
tensors (`x[i, j, ...]` agrees elementwise): the row-major payload is
reshaped through the reversed dims and `aperm`ed back. F32 tensors only;
others (e.g. I64 `num_batches_tracked`) are silently dropped. A 0-d
tensor becomes a length-1 vector.

## See also

[`safetensors_ls()`](https://belian-earth.github.io/garry/reference/safetensors_ls.md)
to list a file's tensors without reading data.
