# Daemon task body: fetch one item-asset's target-window bytes to a local file.

The fetch half of the phase 12 fetch/assemble split: a plain
`gdal_translate -srcwin` of the window intersecting the target extent
(plus a warp-kernel margin), remote COG to local tmpfs, native dtype and
blocks — no warp, no mosaic on the remote path. On failure with
`garry.read_fail = "nodata"`, writes a small all-nodata placeholder
covering the window so the local mosaic reads a hole instead of erroring
(Int16 when a nodata sentinel is declared, Byte 255 otherwise — the HLS
QA convention).

## Usage

``` r
.daemon_fetch_window(
  location,
  out_file,
  ext,
  crs,
  nodata = numeric(0),
  margin = 8L,
  target_res = NULL
)
```

## Arguments

- location:

  Source path/URL.

- out_file:

  Local destination.

- ext, crs:

  Target extent and CRS defining the window.

- nodata:

  Optional sentinel for the failure placeholder.

- margin:

  Source-pixel margin around the window.

## Value

`TRUE`.

## Details

Internal (exported only so mirai daemons can address it via `::`).
