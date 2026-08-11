# List tensor names, dtypes, and shapes without reading data.

List tensor names, dtypes, and shapes without reading data.

## Usage

``` r
safetensors_ls(path)
```

## Arguments

- path:

  Path to a `.safetensors` file.

## Value

Data frame with `name`, `dtype`, `shape` (comma string).

## See also

[`safetensors_read()`](https://belian-earth.github.io/garry/reference/safetensors_read.md)
to read the tensors.
