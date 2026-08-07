# Write a source table as a GTI index for one asset.

Footprints are stored in `crs` (transform them from the table's
EPSG:4326 bboxes), so the index layer SRS matches the grid the GTI
dataset will be pinned to: exact culling geometry, no SRS_BEHAVIOR
juggling, works from GDAL 3.10 up.

## Usage

``` r
stac_gti_index(
  sources,
  asset,
  path = tempfile(fileext = ".gti.fgb"),
  crs = "EPSG:4326"
)
```

## Arguments

- sources:

  A
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  table with a `slice` column (see
  [`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)).

- asset:

  Which asset's rows to index.

- path:

  Index path; defaults to a tempfile.

- crs:

  CRS for the index footprints (use the target grid's CRS).

## Value

The index path, invisibly.
