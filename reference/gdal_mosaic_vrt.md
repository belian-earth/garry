# Mosaic already-grid-aligned rasters into a VRT (adapter).

`gdalbuildvrt` of same-grid single-band rasters: overlapping pixels take
the LAST input, so pass `files` in ascending priority (latest datetime
last, to match the highest-on-top overlap rule). Used to assemble
multi-tile mosaics (e.g. the file form of
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)).

## Usage

``` r
gdal_mosaic_vrt(dst, files)
```

## Arguments

- dst:

  Output VRT path.

- files:

  Grid-aligned input rasters, low-to-high priority.

## Value

`dst`.

## Details

`gdalbuildvrt` takes only north-up sources in one projection and SKIPS,
with a warning, any other: a tile stored south-up (positive north-south
pixel size; every AEF tile, seen 2026-09-25) or a tile in the
neighbouring UTM zone (ESD tiles on the MGRS grid, which overlaps a zone
boundary). A skipped tile would be a hole, or with every tile skipped no
mosaic at all, so a build that lost a source is an error here. It also
averages unequal resolutions and places a tile off the first one's
pixels by resampling. Sources like these do not belong in a mosaic
(`.mosaicable()`): the file form of
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
keeps them as a multi-path source node and the warper reads them
together (`gdal_warp_window()`).
