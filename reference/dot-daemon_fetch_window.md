# Daemon task body: fetch one item-asset's target-window bytes to a local file.

The fetch half of the fetch/assemble split: a plain
`gdal_translate -srcwin` of the window intersecting the target extent
(plus a warp-kernel margin, `.fetch_margin`), remote COG to local tmpfs,
native dtype and blocks; no warp, no mosaic on the remote path.

## Usage

``` r
.daemon_fetch_window(location, out_file, ext, crs, target_res = NULL)
```

## Arguments

- location:

  Source path/URL.

- out_file:

  Local destination.

- ext, crs:

  Target extent and CRS defining the window.

- target_res:

  Target x resolution: a coarser grid decimates the fetch.

## Value

`TRUE`.

## Details

Internal; daemons reach it through `asNamespace("garry")`.
