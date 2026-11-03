# Copy one source's target-window bytes to a local file.

The fetch half of the fetch/assemble split: a plain
`gdal_translate -srcwin` of the window intersecting `ext` (plus
`.fetch_margin`, for the warp kernel), native dtype and blocks; no warp,
no mosaic on the remote path.

## Usage

``` r
gdal_fetch_window(location, out_file, ext, crs, out_res = NULL)
```

## Arguments

- location:

  Source path/URL.

- out_file:

  Local destination GTiff.

- ext, crs:

  Target extent and CRS defining the window.

## Value

`TRUE`, invisibly. Errors if the source is unreadable. A source clear of
the window yields its corner pixel: a tile for the local index that
warps to nothing.
