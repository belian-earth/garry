# Select time slices of a stacked raster by label.

Label selection on the `t` axis (the `.sel(time = ...)` analog): each
selector matches its exact label, or failing that every label it
prefixes (`"2023-06"` selects every June slice); the matches are
combined. Integer/logical positions work too. A selector that matches
nothing is an error. The raster must be a `lazy_stack` along `t` whose
layers were named (slice dates); a single match returns the bare layer.

## Usage

``` r
time_sel(x, sel)
```

## Arguments

- x:

  A `LazyRaster` stacked along `t` with labels.

- sel:

  Character labels/prefixes, or integer/logical positions.

## Value

A `LazyRaster` (the sub-stack, or the single matching layer).
