# Materialise a LazyRaster (or inspect its plan).

Executes the plan and returns the result in the R session, always. To
stream the result to a file instead, use
[`write_tif()`](https://belian-earth.github.io/garry/reference/write_tif.md);
to checkpoint to local cubes and stay lazy, use
[`materialise()`](https://belian-earth.github.io/garry/reference/materialise.md).
`plan_only = TRUE` runs the planner passes and returns the `Plan`
without executing: the permanent introspection path.

## Usage

``` r
collect(x, plan_only = FALSE, distributed = garry_daemons_set())
```

## Arguments

- x:

  A `LazyRaster`, a `LazyDataset` (its bands are assembled along the
  band axis via
  [`stack_bands()`](https://belian-earth.github.io/garry/reference/stack_bands.md)
  first), a named list of lazy rasters (multi-export: one plan, a named
  list of results), or a `LazyDatasetGroups` (one result per group).

- plan_only:

  Return the `Plan` instead of executing?

- distributed:

  Execute across the
  [`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
  pools? Defaults to
  [`garry_daemons_set()`](https://belian-earth.github.io/garry/reference/garry_daemons_set.md),
  so `collect(x)` uses the pools when they are running and runs
  single-threaded otherwise. Pass `TRUE`/`FALSE` to override; the
  distributed result is identical to the single-threaded one.

## Value

With `plan_only = TRUE`, the `Plan`. Otherwise the materialised result
in the R raster convention (spatial-first, layer-last): a scalar for
global reductions, a `[y, x]` matrix for a single layer, or a
`(y, x, band)` array for multiple bands (matching `terra::as.array()`;
plots directly with `rasterImage`/`ximage`). A matrix/array result also
carries a `gis` attribute in the style of
[`gdalraster::read_ds()`](https://firelab.github.io/gdalraster/reference/read_ds.html)
(`type`, `bbox` = `c(xmin, ymin, xmax, ymax)`, `dim` =
`c(nx, ny, nbands)`, `srs` = WKT, `datatype`), so the array is
self-describing and
[`preview()`](https://belian-earth.github.io/garry/reference/preview.md)
can set real-world axes without the grid.
