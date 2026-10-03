# Daemon task body: release all pinned shared-memory regions.

Internal; daemons reach it through `asNamespace("garry")`.

## Usage

``` r
.daemon_shm_clear()
```

## Value

`NULL`, invisibly.
