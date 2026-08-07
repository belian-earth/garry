# Write a garry-oriented matrix into an open output dataset.

NaN cells demote to `nodata` when given (D8 reversed at the sink);
writing NaN into an integer band without a sentinel is an error.

## Usage

``` r
gdal_write_window(
  ds,
  x_off,
  y_off,
  m,
  dtype,
  nodata = numeric(0),
  band = 1L,
  scale = numeric(0),
  offset = numeric(0)
)
```

## Arguments

- ds:

  Open dataset from
  [`gdal_create_output()`](https://belian-earth.github.io/garry/reference/gdal_create_output.md).

- x_off, y_off:

  0-based destination offsets.

- m:

  `[y, x]` matrix.

- dtype:

  Output dtype (for the NaN check).

- nodata:

  Optional sentinel for NaN demotion.

- band:

  1-based destination band.

- scale, offset:

  Optional quantization affine: values are stored as
  `round((v - offset) / scale)` (round-half-even) BEFORE NaN demotes to
  `nodata`, so the sentinel lives in stored units and must sit outside
  the quantized value range.

## Value

Invisibly, `NULL`.
