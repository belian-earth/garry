# Daemon task body: memory hygiene — trim arenas, optionally evict the jit cache.

`deep = TRUE` additionally clears the jit cache (forces recompiles: ~1 s
for map kernels, ~20 s for scans) — reserve it for memory pressure; the
default trim-only pass costs microseconds and gives back what glibc is
hoarding.

## Usage

``` r
.daemon_hygiene(deep = FALSE)
```

## Arguments

- deep:

  Also evict the jit cache?

## Value

`TRUE` if the trim ran (glibc), invisibly.

## Details

Internal (exported only so mirai daemons can address it via `::`).
