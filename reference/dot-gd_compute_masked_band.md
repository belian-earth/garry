# Daemon task body: reduce one band (or strip) under the shared mask.

Reads a band cube plus the shared cleaned-mask cube, applies the
masked-apply function and reduces over time to a raw f32 payload.
Internal; daemons reach it through `asNamespace("garry")`.

## Usage

``` r
.gd_compute_masked_band(job, k)
```
