# Query a STAC API and return the item collection.

Thin port of vrtility's `stac_query()`: GET with POST fallback, full
pagination via `rstac::items_fetch()`.

## Usage

``` r
stac_query(bbox, stac_source, collection, start_date, end_date, limit = 999)
```

## Arguments

- bbox:

  Length-4 numeric, EPSG:4326 (xmin, ymin, xmax, ymax).

- stac_source:

  STAC API root URL.

- collection:

  Collection id.

- start_date, end_date:

  Dates (any lubridate-parseable form).

- limit:

  Page size requested from the API.

## Value

An rstac `doc_items` object.
