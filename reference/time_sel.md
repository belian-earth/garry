# Select time slices of a stacked raster by label.

Label selection on the `t` axis (the `.sel(time = ...)` analog): exact
label matches, or prefix matches for partial datetime strings
(`"2023-06"` selects every June slice), or integer/logical positions.
The raster must be a `lazy_stack` along `t` whose layers were named
(slice dates); a single match returns the bare layer.

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
