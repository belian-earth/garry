# Build GTI open options pinning a target grid and slice filter.

Build GTI open options pinning a target grid and slice filter.

## Usage

``` r
gti_open_options(
  grid = NULL,
  filter = NULL,
  sort_field = NULL,
  sort_asc = TRUE
)
```

## Arguments

- grid:

  Optional `GridSpec`: pins SRS, resolution, and extent so every slice
  opens on exactly this grid.

- filter:

  Optional OGR SQL WHERE clause selecting index features (e.g. one
  datetime slice).

- sort_field, sort_asc:

  Optional deterministic overlap ordering (highest value on top when
  ascending).

## Value

Character vector of "KEY=VALUE" open options.

## See also

[`gti_index_create()`](https://belian-earth.github.io/garry/reference/gti_index_create.md)
