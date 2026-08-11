# Daemon task body: compute the shared cleaned-mask cube.

Replays the mask-cleaning morphology once over the whole QA cube and
writes the resulting f32 mask cube to a file every band task reads,
instead of recomputing the morphology per band. Internal (exported only
so mirai daemons can address it via `::`).

## Usage

``` r
.gd_compute_mask(k)
```
