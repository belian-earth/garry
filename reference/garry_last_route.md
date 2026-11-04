# Which execution route did the last `collect()` take?

A diagnostics helper. garry picks the execution route automatically, and
this reports the route the last
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md),
[`write_tif()`](https://belian-earth.github.io/garry/reference/write_tif.md)
or
[`materialise()`](https://belian-earth.github.io/garry/reference/materialise.md)
took, so pipelines can log it or assert a plan has not changed route.
The values are:

## Usage

``` r
garry_last_route()
```

## Value

`"composite_direct"`, `"gd_reduce"`, `"scheduler"`, `"single"` or
`"read_only"`; `NULL` before any
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
in the session.

## Details

- `"composite_direct"`: the specialised masked-composite executor;

- `"gd_reduce"`: the general reduce-decomposition executor;

- `"scheduler"`: the general distributed scheduler;

- `"single"`: the in-process executor (`distributed = FALSE`);

- `"read_only"`: a plan that only reads and stacks rasters, copied from
  GDAL straight into the result in either mode.
