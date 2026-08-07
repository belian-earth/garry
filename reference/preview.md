# Preview a lazy object, a collected array, or a raster file.

A quick, informative plot: single band as a colour ramp with a legend,
three bands as a stretched RGB composite, categorical data (few distinct
values) with discrete colours. Nodata is transparent; a percentile
`stretch` sets the colour range; axes come from the grid.

## Usage

``` r
preview(
  x,
  bands = NULL,
  max_px = NULL,
  stretch = c(2, 98),
  col = grDevices::hcl.colors(64, "Viridis"),
  legend = NULL,
  main = "",
  axes = TRUE,
  xlab = "",
  ylab = "",
  na_col = NULL,
  ...
)
```

## Arguments

- x:

  A `LazyRaster`, `LazyDataset`, a matrix/array from
  [`collect()`](https://belian-earth.github.io/garry/reference/collect.md),
  or a path to a raster file.

- bands:

  Bands to show: 1 for a colour ramp, 3 for RGB. For a `LazyDataset`,
  band names are also accepted. Defaults to the first 3 bands (RGB) or
  band 1.

- max_px:

  Longest-axis pixel budget for the render; defaults to the device size.

- stretch:

  Percentile cut `c(low, high)` for the colour range, or `NULL` for
  min/max.

- col:

  Colour ramp for single-band plots.

- legend:

  Draw a legend? Defaults to `TRUE` for single band, `FALSE` for RGB.

- main, axes, xlab, ylab:

  Plot title, axes toggle, and axis labels.

- na_col:

  Colour for nodata pixels, or `NULL` (default) to leave them
  transparent. Useful to make a mask's footprint explicit.

- ...:

  Unused.

## Value

`x`, invisibly.

## Details

Inputs are reduced before rendering: a file or an array is decimated to
the device (or `max_px`); a `LazyDataset`/`LazyRaster` is re-planned at
a coarse resolution so it fetches only what the preview shows
(grid-pinned sources only; otherwise it collects at full resolution and
decimates).
