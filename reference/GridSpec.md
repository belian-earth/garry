# Spatial grid specification.

The constructor canonicalises `crs` to GDAL WKT, so two GridSpecs built
from "EPSG:4326" and the equivalent proj4/WKT string compare equal.

## Usage

``` r
GridSpec(crs, transform, extent, dims, dtype, labels = list())
```

## Arguments

- crs:

  CRS string in any GDAL-interpretable form.

- transform:

  GDAL geotransform, length 6, north-up.

- extent:

  Numeric length 4: xmin, ymin, xmax, ymax.

- dims:

  Integer dimensions: nx, ny (optionally nt, nb).

- dtype:

  dtype string from the garry vocabulary.

- labels:

  Optional named list of character vectors labelling the non-spatial
  dims (slice dates on `t`, band names on `band`); each length-matched
  to its dim. Metadata only: planning ignores labels.

## Value

A `GridSpec`.
