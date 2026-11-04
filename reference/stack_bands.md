# Collapse a dataset's bands into a single stacked raster.

The dataset -\> array operation (xarray's `Dataset.to_dataarray()`):
stacks the bands along a new `band` axis. Needs one layer per band, so
reduce time first (`reduce_over(ds, "median", "t")`). This is the hook
for a reducer over the band axis, such as
[`band_project()`](https://belian-earth.github.io/garry/reference/band_project.md)
or
[`mlp_project()`](https://belian-earth.github.io/garry/reference/mlp_project.md)
with `over = "band"`;
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
calls it implicitly. A reducer that needs bands and time together, such
as
[`geomedian()`](https://belian-earth.github.io/garry/reference/geomedian.md),
takes a `(band, t, y, x)` cube from
`lazy_stack(list(B02 = ds[["B02"]], ...), along = "band")` instead.

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
