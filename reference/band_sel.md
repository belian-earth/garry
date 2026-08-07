# Select bands of a stacked raster by label.

As
[`time_sel()`](https://belian-earth.github.io/garry/reference/time_sel.md),
on the `band` axis.

## Usage

``` r
band_sel(x, sel)
```

## Arguments

- x:

  A `LazyRaster` stacked along `band` with labels.

- sel:

  Character labels/prefixes, or integer/logical positions.

## Value

A `LazyRaster`.
