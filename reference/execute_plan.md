# Execute a Plan on the anvl backend (single-threaded).

Execute a Plan on the anvl backend (single-threaded).

## Usage

``` r
execute_plan(plan, path = NULL, nodata = NULL, band_names = NULL)
```

## Arguments

- plan:

  A `Plan`.

- path:

  Optional GTiff destination: the sink raster is written chunk by chunk
  instead of returned in memory.

- nodata:

  Optional sentinel recorded in the output and used to demote NaN on
  write (required for integer outputs containing NaN).

- band_names:

  Optional character vector of band descriptions written to the output
  bands (multiband GTiff).

## Value

The sink stage's value (matrix for raster sinks, scalar for global
reductions), or `path` invisibly when writing. When
`options(garry.exec_stats = TRUE)`, in-memory results carry a
`garry_exec_stats` attribute with the distinct input shapes submitted
per stage (kernel-cache accounting).
