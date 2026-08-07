# Convenience constructor: derive the transform from extent + dims (or res).

Give the pixel grid either directly as `dims` (nx, ny) or as `res`
(pixel size), from which `dims` is derived and the `extent` snapped to a
whole number of pixels. Exactly one of the two.

## Usage

``` r
grid_spec(crs, extent, dims = NULL, dtype = "f32", res = NULL)
```

## Arguments

- crs:

  CRS string in any GDAL-interpretable form.

- extent:

  Numeric length 4: xmin, ymin, xmax, ymax.

- dims:

  Integer dimensions `c(nx, ny)`. Provide this OR `res`, not both.

- dtype:

  dtype string from the garry vocabulary.

- res:

  Pixel resolution in the units of `crs`: a scalar (square pixels) or
  `c(xres, yres)`. Derives `dims` from `extent` and snaps `extent` to a
  whole number of pixels (anchored at the top-left, so the resolution is
  exactly `res`). Provide this OR `dims`, not both.

## Value

A `GridSpec`.
