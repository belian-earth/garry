# Copy one source's target-window bytes to a local file.

The fetch half of the fetch/assemble split: a plain
`gdal_translate -srcwin` of the window intersecting `ext` (plus a
warp-kernel `margin` in source pixels), native dtype and blocks; no
warp, no mosaic on the remote path.

## Usage

``` r
gdal_fetch_window(location, out_file, ext, crs, margin = 8L, out_res = NULL)
```

## Arguments

- location:

  Source path/URL.

- out_file:

  Local destination GTiff.

- ext, crs:

  Target extent and CRS defining the window.

- margin:

  Source-pixel margin around the window.

## Value

`TRUE`, invisibly. Errors if the window is empty or the source
unreadable.
