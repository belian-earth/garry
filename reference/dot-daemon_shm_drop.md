# Daemon task body: release named shared-memory regions.

Internal (exported only so mirai daemons can address it via `::`).

## Usage

``` r
.daemon_shm_drop(keys)
```

## Arguments

- keys:

  Registry keys to drop (missing keys are ignored).

## Value

`NULL`, invisibly.
