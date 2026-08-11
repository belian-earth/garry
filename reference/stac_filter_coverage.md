# Drop STAC items (or sources) that barely overlap an area of interest.

Keeps items whose bounding box covers at least `min_coverage` of the AOI
`bbox` (fraction of the AOI area, from a planar bbox overlap – a fast
proxy, not geodesic). Works on a STAC `doc_items` or a
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
table.

## Usage

``` r
stac_filter_coverage(sources, bbox, min_coverage = 0.5)
```

## Arguments

- sources:

  A STAC `doc_items` or a
  [`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
  data frame.

- bbox:

  AOI bounding box `c(xmin, ymin, xmax, ymax)` in the item CRS (STAC
  bboxes are lon/lat).

- min_coverage:

  Minimum AOI-overlap fraction to keep an item (0-1).

## Value

The filtered `doc_items` / data frame.

## See also

Other stac helpers:
[`lazy_stac_stack()`](https://belian-earth.github.io/garry/reference/lazy_stac_stack.md),
[`stac_drop_duplicates()`](https://belian-earth.github.io/garry/reference/stac_drop_duplicates.md),
[`stac_filter_assets()`](https://belian-earth.github.io/garry/reference/stac_filter_assets.md),
[`stac_filter_cloud()`](https://belian-earth.github.io/garry/reference/stac_filter_cloud.md),
[`stac_filter_orbit()`](https://belian-earth.github.io/garry/reference/stac_filter_orbit.md),
[`stac_gti_index()`](https://belian-earth.github.io/garry/reference/stac_gti_index.md),
[`stac_merge()`](https://belian-earth.github.io/garry/reference/stac_merge.md),
[`stac_query()`](https://belian-earth.github.io/garry/reference/stac_query.md),
[`stac_rename_assets()`](https://belian-earth.github.io/garry/reference/stac_rename_assets.md),
[`stac_sign_mpc()`](https://belian-earth.github.io/garry/reference/stac_sign_mpc.md),
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md),
[`stac_time_slices()`](https://belian-earth.github.io/garry/reference/stac_time_slices.md)
