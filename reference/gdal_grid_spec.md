# Inspect a GDAL source and build its GridSpec (plus read metadata).

Inspect a GDAL source and build its GridSpec (plus read metadata).

## Usage

``` r
gdal_grid_spec(path, band = 1L, open_options = character(0))
```

## Arguments

- path:

  Path or VSI URL readable by GDAL.

- band:

  1-based band index.

- open_options:

  GDAL open options ("KEY=VALUE").

## Value

A list: `grid` (`GridSpec`), `nodata` (length 0 or 1), `block_dim`
(integer length 2, x then y), and `scale`/`offset` (each length 0 when
the band carries no scaling metadata).
