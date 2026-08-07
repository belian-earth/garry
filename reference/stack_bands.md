# Collapse a dataset's bands into a single stacked raster.

The dataset -\> array operation (xarray's `Dataset.to_dataarray()`):
stacks the bands along a new `band` axis. Needs one layer per band, so
reduce time first (`reduce_over(ds, "median", "t")`). This is the hook
for a multiband reducer that must see all bands jointly (e.g. geometric
median);
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
calls it implicitly.

## Usage

``` r
stack_bands(x)
```

## Arguments

- x:

  A `LazyDataset`.

## Value

A `LazyRaster` (the single band if there is one, else a `(band, y, x)`
stack).
