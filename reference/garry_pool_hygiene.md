# Reclaim daemon memory across the pools.

Broadcasts
[`.daemon_hygiene()`](https://belian-earth.github.io/garry/reference/dot-daemon_hygiene.md)
to every pool: return freed heap pages to the OS (glibc `malloc_trim`),
and with `deep = TRUE` also evict the daemons' jit caches (forces
recompiles on next use — ~1 s per map kernel, ~20 s per scan kernel;
reserve for memory pressure). The scheduler already trims after every
compute/write task and at run start; call this between pipeline phases
when the fleet should idle lean.

## Usage

``` r
garry_pool_hygiene(deep = FALSE)
```

## Arguments

- deep:

  Also evict the jit caches?

## Value

Invisibly `NULL`.
