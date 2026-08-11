# Write a source table as a GTI index for one asset.

A GTI index is a vector layer of raster footprints read by GDAL's GTI
(GDAL Tile Index) raster driver, available from GDAL 3.10, which mosaics
the indexed rasters on the fly. Footprints are stored in `crs`
(transformed from the table's EPSG:4326 bboxes), so the index layer SRS
matches the grid the GTI dataset will be pinned to and the culling
geometry is exact. Most users reach this via
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
or
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
which build the index internally, and rarely call it directly.

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

## See also

Other stac helpers:
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
[`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md),
[`stac_filter_assets()`](https://belian-earth.github.io/garry/reference/stac_filter_assets.md),
[`stac_filter_cloud()`](https://belian-earth.github.io/garry/reference/stac_filter_cloud.md),
[`stac_filter_coverage()`](https://belian-earth.github.io/garry/reference/stac_filter_coverage.md),
[`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md),
[`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md),
[`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md),
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
