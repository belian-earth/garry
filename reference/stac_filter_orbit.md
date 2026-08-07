# Filter STAC items by orbit state (Sentinel-1 ascending / descending).

Keeps items whose `sat:orbit_state` is in `orbit_state`. STAC-only: the
orbit state is not carried in the
[`stac_sources()`](https://belian-earth.github.io/garry/reference/stac_sources.md)
table, so pass a `doc_items` (filter before building the dataset).

## Usage

``` r
stac_filter_orbit(sources, orbit_state = c("descending", "ascending"))
```

## Arguments

- sources:

  A STAC `doc_items`.

- orbit_state:

  One or more of `"descending"`, `"ascending"`.

## Value

The filtered `doc_items`.
