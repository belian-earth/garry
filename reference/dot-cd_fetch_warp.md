# Daemon task body: warp one slice's remote items into an f32 buffer.

Internal (exported only so mirai daemons can address it via `::`).

## Usage

``` r
.cd_fetch_warp(j, k)
```

## Arguments

- j:

  Per-slice job (locs/dt/nodata/resampling/bin).

- k:

  Grid-constant bundle (nx/ny/gtstr/wkt).

## Value

List with `err`, `tf`, `tw`.
