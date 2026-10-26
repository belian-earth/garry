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
  band = 1L,
  nodata = numeric(0),
  partial = FALSE,
  decode = FALSE
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

  1-based band index (or indices) the read will use. Their data types
  drive the integer gate above.

- nodata:

  The source node's sentinel (length 0 or 1). Averaging declines unless
  the file declares the same value.

- partial:

  `TRUE` for one source of several
  ([`.mosaic_read_spec()`](https://belian-earth.github.io/garry/reference/dot-mosaic_read_spec.md)):
  the target may reach beyond the source, and only a nearest-neighbour
  read on the source's own pixels, with the file's nodata (if any) the
  node's, qualifies.

- decode:

  `TRUE` for the codes behind a decoded source (`.gdal_read_decoded()`):
  integer bands qualify for `"near"` and `"average"`, the two reads that
  decode applies itself, and no others.

## Value

`NULL`, or a list with `fx`, `fy`, `x_off`, `y_off` (the target origin
in source pixels, rows counted from the north), `resamp`, `flip`, and
the source's `nx` and `ny`.

## Details

A target CRS that differs from the source's only by its false origin
(UTM north and south of one zone: a store in 326NN read onto a southern
327NN grid) is the source CRS shifted by a constant, so the target maps
onto a window of the source just the same. The warper reprojects every
pixel there to reach the same cells; a nearest- neighbour read of a
128-band OlmoEarth Zarr window took 8x longer through it. Such a target
takes the fast path for nearest-neighbour reads only, the one read that
matches the warper on every GDAL version.

Integer bands are the one exception to that identity: an interpolating
resampler produces fractional values that each engine rounds back to the
band type itself, and under GDAL 3.13.1 on ARM (new NEON float-\>int
conversion paths) RasterIO and the warper round .5 ties in opposite
directions – every tie came back +1 DN through the fast path on the
macOS CI runners. Identity is the contract, so integer bands take the
fast path only for NEAREST, where no rounding happens.

A south-up source (positive y pixel size: every AEF tile) stores its
rows from the south. A target on its own pixels is still a window of it,
read with its rows reversed (`flip`), the read
[`gdal_read_window()`](https://belian-earth.github.io/garry/reference/gdal_read_window.md)
gives any south-up file; a decimating target keeps the warper.

Returns `NULL` (keep the warper) unless every condition holds, so the
warper stays the default and this is a pure opt-in fast path.
