# Materialise a LazyRaster (or inspect its plan).

`plan_only = TRUE` runs the planner passes and returns the `Plan`
without executing: the permanent introspection path.

## Usage

``` r
collect(
  x,
  plan_only = FALSE,
  path = NULL,
  nodata = NULL,
  distributed = garry_daemons_set(),
  band_names = NULL
)
```

## Arguments

- x:

  A `LazyRaster`, or a `LazyDataset` (its bands are assembled along the
  band axis via
  [`stack_bands()`](https://belian-earth.github.io/garry/reference/stack_bands.md)
  first).

- plan_only:

  Return the `Plan` instead of executing?

- path:

  Optional GTiff destination; the result is written chunk by chunk and
  the path returned invisibly.

- nodata:

  Optional sentinel for the written file (NaN demotes to it; required
  for integer outputs containing nodata).

- distributed:

  Execute across the
  [`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
  pools? Defaults to
  [`garry_daemons_set()`](https://belian-earth.github.io/garry/reference/garry_daemons_set.md),
  so `collect(x)` uses the pools when they are running and runs
  single-threaded otherwise. Pass `TRUE`/`FALSE` to override; the
  distributed result is identical to the single-threaded one.

- band_names:

  Output band descriptions for file writes. Usually inferred (a
  dataset's band names; a stack's layer labels). For a multi-export list
  input, a NAMED LIST keyed by sink name gives each sink its own
  descriptions.

## Value

With `plan_only = TRUE`, the `Plan`. With `path`, the path, invisibly.
Otherwise the materialised result in the R raster convention
(spatial-first, layer-last): a scalar for global reductions, a `[y, x]`
matrix for a single layer, or a `(y, x, band)` array for multiple bands
(matching `terra::as.array()`; plots directly with
`rasterImage`/`ximage`). A matrix/array result also carries a `gis`
attribute in the style of
[`gdalraster::read_ds()`](https://firelab.github.io/gdalraster/reference/read_ds.html)
(`type`, `bbox` = `c(xmin, ymin, xmax, ymax)`, `dim` =
`c(nx, ny, nbands)`, `srs` = WKT, `datatype`), so the array is
self-describing and
[`preview()`](https://belian-earth.github.io/garry/reference/preview.md)
can set real-world axes without the grid.
