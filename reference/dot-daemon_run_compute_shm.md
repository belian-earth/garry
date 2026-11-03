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
  edge = NULL,
  wq = NULL,
  grow = NULL,
  ring = NULL
)
```

## Arguments

- cache_key:

  Per-run jit cache key.

- fn:

  Stage kernel (a closure or a program set), NULL on a key-only launch;
  `in_vals`/`in_keys`/`trims`/`dtypes` describe the inputs (`in_keys`
  name the element to extract from each shared value: the node key, or a
  part name for coarse reads); `reg_key` the daemon registry slot for
  the result. `grow` = c(rows, cols) pads an edge chunk's inputs to the
  stage's modal chunk shape and crops the outputs back (see
  `.sv_grow()`). `ring` holds the chunk's cells past the raster for a
  kernel that takes them (see `.ring_cells()`).

## Value

The shared result (serialises as its region name).
