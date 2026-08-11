# Read a window from a GDAL source as a garry-oriented matrix.

Returns the window with row 1 = northernmost. Offsets are 0-based pixel
coordinates. If `nodata` is supplied, matching cells (and any file-level
NA) are rewritten to NaN and the result is numeric.

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
  out = c("matrix", "raw_f32"),
  scale = numeric(0),
  offset = numeric(0)
)
```

## Arguments

- path:

  Path or VSI URL readable by GDAL.

- band:

  1-based band index, or a vector of them for a multi-band read in one
  pass.

- x_off, y_off, x_size, y_size:

  0-based pixel window.

- nodata:

  Length-0 or length-1 sentinel to promote to NaN.

- open_options:

  GDAL open options ("KEY=VALUE").

- out:

  Output form: `"matrix"` (default) returns an R numeric result;
  `"raw_f32"` returns the pixels packed as a raw row-major f32 payload,
  avoiding a numeric copy when the result feeds a binary store or
  another process.

- scale, offset:

  Length-0 (absent) or length-1 band affine: values become
  `v * scale + offset` after the nodata sentinel is promoted to NaN, so
  sentinels never scale.

## Value

With `out = "matrix"`: a numeric `y_size x x_size` matrix for a single
band, or a `(band, y, x)` numeric array when `band` is a vector. With
`out = "raw_f32"`: a raw row-major f32 payload (band planes contiguous
when `band` is a vector).
