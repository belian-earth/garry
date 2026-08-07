# Which execution route did the last `collect()` take?

The distributed
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
silently picks between the composite-direct fast path, the
reduce-decomposition path and the staged scheduler (in that order);
single-threaded runs use the in-process executor. The chosen route is
recorded per
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
call so equivalence tests and pipelines can assert a plan did not
silently change route.

## Usage

``` r
garry_last_route()
```

## Value

`"composite_direct"`, `"gd_reduce"`, `"scheduler"` or `"single"`; `NULL`
before any
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
in the session.
