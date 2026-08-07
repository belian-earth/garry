# Execute a composite via the split-pool fetch-ordered pipeline.

Fetch fmask first on the read pool; compute the cleaned mask on the
compute pool while the bands download; then dispatch each band's median
as its fetch lands, so band B's median runs while later bands are still
fetching. Only the last band's median is exposed after the drain.
Requires a garry_daemons split.

## Usage

``` r
.execute_composite_pipeline(
  plan,
  spec,
  path = NULL,
  nodata = NULL,
  band_names = NULL
)
```
