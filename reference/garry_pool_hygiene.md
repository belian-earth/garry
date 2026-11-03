# Reclaim daemon memory across the pools.

Asks every daemon in the pools to release caches and return freed heap
pages to the operating system (glibc `malloc_trim`). With `deep = TRUE`
the daemons' jit caches are also evicted, forcing recompiles on next use
(roughly a second per map kernel, tens of seconds per scan kernel);
reserve that for memory pressure. Daemons already trim at run start, and
during a run once 128 MB of task transients have passed since their last
trim; call this between pipeline phases when the fleet should idle lean.

## Usage

``` r
garry_pool_hygiene(deep = FALSE)
```

## Arguments

- deep:

  Also evict the jit caches?

## Value

Invisibly `NULL`.

## See also

[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
