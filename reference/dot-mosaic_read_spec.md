# How a nearest-neighbour read of several sources is served.

Tiles no mosaic VRT can hold (south-up tiles, tiles in a neighbouring
projection, one Zarr array per UTM zone) stay a multi-path source. A
nearest-neighbour read of it takes each target cell from one source
pixel, a later source winning where it holds data, so the sources can be
read one at a time and laid over each window in order
(`gdal_read_window_multi()`): a direct window read where a source lies
on the target's pixels
([`.rio_direct_spec()`](https://belian-earth.github.io/garry/reference/dot-rio_direct_spec.md),
`partial = TRUE`), and elsewhere an exact nearest-neighbour warp of that
source alone, clipped to its footprint. Only the sources off the
target's pixels pay for warping, and the cells are those the warper
gives all the sources together.

## Usage

``` r
.mosaic_read_spec(paths, target_grid, band = 1L, nodata = numeric(0))
```

## Arguments

- paths:

  The source paths, in mosaic order.

- target_grid:

  The `WarpNode` target
  [`GridSpec()`](https://belian-earth.github.io/garry/reference/GridSpec.md).

- band:

  1-based band index (or indices) the read will use. Their data types
  drive the integer gate above.

- nodata:

  The source node's sentinel (length 0 or 1). Averaging declines unless
  the file declares the same value.

## Value

`NULL` (the warper reads them together), or a list with `fx = fy = 1`,
`resamp`, the target `grid` and `parts`, one a source: its
[`.rio_direct_spec()`](https://belian-earth.github.io/garry/reference/dot-rio_direct_spec.md)
result, or `list(warp = TRUE)`, each with `box`, its footprint in target
pixels `c(c0, r0, c1, r1)`.

## Details

Float sources whose nodata is not NaN keep the warper when any two
overlap: it lets a later source's NaN value cover an earlier source's
data, which a paste that skips NaN cannot tell from nodata. Memoised per
sources (and their local file stamps), target, bands and nodata.
