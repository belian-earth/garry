# Daemon task body: run one jitted stage closure on shared-memory inputs.

Internal; daemons reach it through `asNamespace("garry")`.

## Usage

``` r
.daemon_run_compute_shm(
  cache_key,
  fn,
  in_vals,
  in_keys,
  trims,
  dtypes,
  reg_key,
  out_keys = NULL,
  device = "cpu",
  store_raw = FALSE,
  edge = NULL,
  wq = NULL,
  grow = NULL
)
```

## Arguments

- cache_key:

  Per-run jit cache key.

- fn:

  Stage closure; `in_vals`/`in_keys`/`trims`/`dtypes` describe the
  inputs (`in_keys` name the element to extract from each shared value:
  the node key, or a part name for coarse reads); `reg_key` the daemon
  registry slot for the result. `grow` = c(rows, cols) pads an edge
  chunk's inputs to the stage's modal chunk shape and crops the outputs
  back (see `.sv_grow()`).

## Value

The shared result (serialises as its region name).
