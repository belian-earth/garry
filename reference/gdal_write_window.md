# Write a garry-oriented matrix into an open output dataset.

NaN cells are converted back to the sink `nodata` value when given;
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
  plane = 1L
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

- plane:

  For a rank-3 `(band, y, x)` raw store payload, the 1-based plane to
  write (taken by byte offset, no copy of the rest).

## Value

Invisibly, `NULL`.
