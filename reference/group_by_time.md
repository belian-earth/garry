# Group a dataset's time slices into calendar periods.

Partitions every band's slices by period so a following
`reduce_over(over = "t")` builds one composite per group: a year of
daily imagery, `group_by_time("month")`, then a median gives twelve
monthly composites (xarray's `resample(time = ...).reduce()`). Slices
are grouped by the period prefix of their date name, so build the
dataset at `granularity = "day"` and group up from there. Ragged bands
are fine – a band with no slice in a group is simply absent from that
group's composite.

## Usage

``` r
group_by_time(x, by = "month")
```

## Arguments

- x:

  A `LazyDataset`.

- by:

  `"year"`, `"quarter"`, `"month"` (default), `"week"`, `"day"`, or a
  function mapping a slice name to a group label.

## Value

A `LazyDatasetGroups` (a named list of per-group `LazyDataset`s). Reduce
it with
[`reduce_over()`](https://belian-earth.github.io/garry/reference/reduce_over.md),
then
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
returns a named list of results (or writes one file per group when
`path` carries a `{group}` placeholder, e.g. `"ndvi_{group}.tif"`).
