# Are the garry daemon pools set?

`TRUE` from
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
creating read and compute pools until they are torn down. This is the
default for the `distributed` argument of
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md),
so `collect(x)` uses the pools when they are set and runs
single-threaded otherwise. Mirrors
[`mirai::daemons_set()`](https://mirai.r-lib.org/reference/daemons_set.html):
it says the pools were set, not that every daemon is alive, so a pool
that lost its daemons stays `TRUE` and the next run fails with a
`garry_pool_error`, rather than moving onto the process the pools
protect.
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
restarts them.

## Usage

``` r
garry_daemons_set()
```

## Value

A single logical.
