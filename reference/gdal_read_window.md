# Read a window from a GDAL source as a garry-oriented matrix.

Returns a `[y, x]` matrix (row 1 = northernmost). Offsets are 0-based
pixel coordinates. If `nodata` is supplied, matching cells (and any
file-level NA) are rewritten to NaN (D8) and the result is numeric.

## Usage

``` r
gdal_read_window(
  path,
  band,
  x_off,
  y_off,
  x_size,
  y_size,
  nodata = numeric(0),
  open_options = character(0),
  out = c("matrix", "raw_f32")
)
```

## Arguments

- path:

  Path or VSI URL readable by GDAL.

- band:

  1-based band index.

- x_off, y_off, x_size, y_size:

  0-based pixel window.

- nodata:

  Length-0 or length-1 sentinel to promote to NaN.

- open_options:

  GDAL open options ("KEY=VALUE").

- out:

  Output form: a `[y, x]` `"matrix"` (default), or a raw f32 store value
  (`"raw_f32"`) for the distributed store path.

## Value

A numeric `y_size x x_size` matrix.
