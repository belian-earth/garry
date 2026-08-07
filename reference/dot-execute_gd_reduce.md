# Execute a reduce-decomposable plan: overlap-compute the leaf reduces, then run the upper IR on the materialised results.

Execute a reduce-decomposable plan: overlap-compute the leaf reduces,
then run the upper IR on the materialised results.

## Usage

``` r
.execute_gd_reduce(plan, decomp, path = NULL, nodata = NULL, band_names = NULL)
```
