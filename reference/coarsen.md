# Coarsen a raster or dataset by block means.

Maps `x` onto the grid `factor` times coarser, anchored on its origin:
each coarse cell is the mean of the valid (non-NaN) values of its
`factor` x `factor` block, NaN when none is valid. This is exact block
arithmetic, not a GDAL resampler, so the two stages stay explicit: a
decoded embedding read by nearest neighbour onto a 10 m grid, then
averaged to 30 m,

## Usage

``` r
coarsen(x, factor, fun = "mean")
```

## Arguments

- x:

  A `LazyRaster` or `LazyDataset` reading its sources.

- factor:

  Integer block size (\>= 1).

- fun:

  Block statistic; only `"mean"`.

## Value

A `LazyRaster` or `LazyDataset` on the coarser grid (f32).

## Details

    codes <- lazy_dataset(tiles, grid10, resampling = "near", decode = dequantize_aef)
    cube <- stack_bands(coarsen(codes, 3L))

takes, for each 30 m cell, the mean of the nine decoded 10 m values the
10 m read gives, never a GDAL average over the reprojected source
footprint. The coarsening runs inside the read: each window's finer
cells are assembled from the sources as the nearest-neighbour read of
them assembles them (a direct window read of a source on those cells'
pixels, a nearest warp of any other source alone, later sources winning
where they hold data), decoded, and averaged in one pass, so the finer
grid is never written. Cells warped from a reprojected source match the
finer read's under `garry.warp_exact = TRUE`; with GDAL's approximate
transformer (the default) a cell near a pixel boundary can take the
neighbouring pixel.

Version 1 coarsens reads only: `x` must come straight from
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
or
[`lazy_source()`](https://belian-earth.github.io/garry/reference/lazy_source.md)
(decoded or not) by nearest-neighbour, from sources opened without open
options, and its dims must divide by `factor`. A dataset with a
`mask_asset` is refused: averaging a mask band's bits would invent
flags.
