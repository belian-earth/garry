# Mosaic already-grid-aligned rasters into a VRT (adapter).

`gdalbuildvrt` of same-grid single-band rasters: overlapping pixels take
the LAST input, so pass `files` in ascending priority (latest datetime
last, to match the highest-on-top overlap rule). Used to assemble a
per-slice mosaic from cptkirk's per-tile warp outputs.

## Usage

``` r
gdal_mosaic_vrt(dst, files, te = NULL, ts = NULL, vrtnodata = NULL)
```

## Arguments

- dst:

  Output VRT path.

- files:

  Grid-aligned input rasters, low-to-high priority.

## Value

`dst`.
