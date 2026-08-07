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
