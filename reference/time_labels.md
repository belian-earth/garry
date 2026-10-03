# Time labels of a lazy object

The labels on the `t` axis: one per slice, typically acquisition dates
or the period labels
[`group_by_time()`](https://belian-earth.github.io/garry/reference/group_by_time.md)
assigns.

## Usage

``` r
time_labels(x)
```

## Arguments

- x:

  A `LazyRaster`, `GridSpec` or `LazyDataset`.

## Value

A character vector, or `NULL` when there is no labelled `t` axis. For a
`LazyDataset` whose value bands carry different labels, a list named by
band.

## Examples

``` r
g <- grid_spec(c(0, 0, 100, 50), res = 10, crs = "EPSG:3857")
time_labels(g)
#> NULL
```
