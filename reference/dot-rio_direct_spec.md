# Can this warp be served by a plain decimating RasterIO read?

A `WarpNode` whose target grid shares the source CRS, is axis-aligned,
starts on a source pixel boundary and has a whole-number pixel size
needs no warping at all: GDAL's RasterIO reads the window and resamples
it in one pass, which is measurably cheaper than building a warped VRT
and reading through the warper (2.6x on a 4-band Landsat
crop+3x-average, 0.98s -\> 0.375s). Results are identical, including
overview selection and nodata handling at fill boundaries, because both
paths hand the same request to the same GDAL resampler.

## Usage

``` r
.rio_direct_spec(
  src_path,
  target_grid,
  resampling,
  open_options = character(0),
  band = 1L
)
```

## Arguments

- src_path:

  Source path or VSI URL.

- target_grid:

  The `WarpNode` target
  [`GridSpec()`](https://belian-earth.github.io/garry/reference/GridSpec.md).

- resampling:

  Requested resampling name.

- open_options:

  Source open options; any at all keep the warper (GTI and other
  option-driven sources are left alone in v1).

- band:

  1-based band index the read will use; must be a single band (the
  decimating read is single-band). Its data type drives the integer gate
  above.

## Value

`NULL`, or a list with `fx`, `fy`, `x_off`, `y_off`, `resamp`.

## Details

Integer bands are the one exception to that identity: an interpolating
resampler produces fractional values that each engine rounds back to the
band type itself, and under GDAL 3.13.1 on ARM (new NEON float-\>int
conversion paths) RasterIO and the warper round .5 ties in opposite
directions – every tie came back +1 DN through the fast path on the
macOS CI runners. Identity is the contract, so integer bands take the
fast path only for NEAREST, where no rounding happens.

Returns `NULL` (keep the warper) unless every condition holds, so the
warper stays the default and this is a pure opt-in fast path.
