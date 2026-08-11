# Are the garry daemon pools running?

`TRUE` when the read and compute daemon pools created by
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
are running. This is the default for the `distributed` argument of
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md),
so `collect(x)` uses the pools when they are up and runs single-threaded
otherwise. Mirrors
[`mirai::daemons_set()`](https://mirai.r-lib.org/reference/daemons_set.html).

## Usage

``` r
garry_daemons_set()
```

## Value

A single logical.
