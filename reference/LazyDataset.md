# A named, multi-band, multi-time lazy dataset.

The dataset holds one entry per band; each entry is a list of
per-time-slice `LazyRaster`s on a shared grid and IR graph. Build one
with
[`lazy_dataset()`](https://belian-earth.github.io/garry/reference/lazy_dataset.md)
(from a STAC source table) or
[`as_dataset()`](https://belian-earth.github.io/garry/reference/as_dataset.md)
(from `LazyRaster`s you already have). Apply
[`lazy_map()`](https://belian-earth.github.io/garry/reference/lazy_map.md),
[`focal()`](https://belian-earth.github.io/garry/reference/focal.md),
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md)
and [`mask()`](https://belian-earth.github.io/garry/reference/mask.md)
across all bands; index a single band with `ds[["B04"]]` or a
sub-dataset with `ds[c("B04", "B03")]`;
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
to materialise.

## Usage

``` r
LazyDataset(
  graph = Graph(),
  bands = list(),
  mask_asset = character(0),
  steps = list()
)
```

## Arguments

- graph:

  The shared IR `Graph`.

- bands:

  Named list; each element is a list of per-slice `LazyRaster`s.

- mask_asset:

  Length-0 or length-1 name of the QA/mask band, if any.

- steps:

  Display-only pipeline log (list of `.step()`s), shown by
  [`draw()`](https://belian-earth.github.io/garry/reference/draw.md);
  does not affect execution.

## Value

A `LazyDataset`.
