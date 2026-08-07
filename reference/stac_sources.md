# Rectangularise STAC items into a source table.

One row per item x asset: `location` (GDAL-readable href), `asset`,
`datetime`, `cloud_cover`, footprint columns (`xmin`..`ymax`, EPSG: 4326
from the item bbox), and `item_id`. This table is the single interface
between discovery and the mosaic layer; filters below operate on it in
plain R.

## Usage

``` r
stac_sources(items, assets = NULL)
```

## Arguments

- items:

  An rstac `doc_items` object (or any list with the same `features`
  structure).

- assets:

  Optional character vector restricting assets.

## Value

A data.frame.
