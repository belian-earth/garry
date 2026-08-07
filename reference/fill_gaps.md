# Fill nodata gaps along the time axis.

The temporal gap-filling verbs xarray spells `ffill`/`bfill`/
`interpolate_na`, expressed on garry's own IR as
[`scan_over()`](https://belian-earth.github.io/garry/reference/scan_over.md)
bodies (documented here rather than left as folklore):

- `"ffill"` carries the last valid value forward;

- `"bfill"` carries the next valid value backward;

- `"linear"` interpolates between the nearest valid neighbours
  (index-weighted, i.e. by slice position, not calendar spacing),
  falling back to ffill/bfill at the ends.

## Usage

``` r
fill_gaps(x, method = c("ffill", "bfill", "linear"), over = "t")
```

## Arguments

- x:

  A `LazyRaster` with a `t` dim, or a `LazyDataset`.

- method:

  `"ffill"`, `"bfill"` or `"linear"`.

- over:

  Axis to fill along (only `"t"` is meaningful today).

## Value

The filled object, same class as `x`.

## Details

Works on a `(t, y, x)` `LazyRaster` cube or per band of a `LazyDataset`.
All-nodata pixels stay NaN.
