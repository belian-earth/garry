# Daemon task body: warp one slice's remote items into an f32 buffer.

Internal; daemons reach it through `asNamespace("garry")`.

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

List with `err` and `tw` (warp seconds).
