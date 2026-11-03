# Daemon task body: bring one slice's items to an f32 plane file.

One item on the grid's own pixels is translated; anything else warps
into an f32 buffer.

## Usage

``` r
.cd_fetch_warp(j, k)
```

## Arguments

- j:

  Per-slice job (locs/dt/band/nodata/resampling/bin).

- k:

  Grid-constant bundle (nx/ny/grid/gtstr/wkt).

## Value

List with `tw` (read seconds) and `how`, `"translate"` or `"warp"`.

## Details

Internal; daemons reach it through `asNamespace("garry")`.
