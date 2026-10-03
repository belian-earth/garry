# Daemon task body: release named shared-memory regions.

Internal; daemons reach it through `asNamespace("garry")`.

## Usage

``` r
.daemon_shm_drop(keys)
```

## Arguments

- keys:

  Registry keys to drop (missing keys are ignored).

## Value

`NULL`, invisibly.
