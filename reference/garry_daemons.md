# Set up split mirai daemon pools for distributed execution.

Two pools instead of one: `read` daemons execute source/warp read tasks
(and any kernels the placement pass fuses onto them), while `compute`
daemons run the materialised XLA stages. The resource model is: **pool
width is slots, admission is concurrency**. Every daemon is pinned to a
disjoint slice of the machine at creation
(`garry_opt("pool_affinity")`), so an XLA client created anywhere is
narrow rather than all-cores; the scheduler's live-RAM byte budgets
decide how many tasks are actually in flight; excess daemons idle lean.
Called with no arguments it sizes the pools to the machine: `read` = all
logical cores (remote fetch is latency-bound, so a wide read pool keeps
the network drain full) and `compute` = a third of the logical cores,
capped at 8 with a floor of 2; on CUDA the compute pool is 2, since
concurrent clients share one card. `collect(distributed = TRUE)` detects
the pools automatically and pre-compiles stage kernels at run start
(`garry_opt("jit_warmup")`), scan kernels included, targeted at the
`garry_opt("scan_profiles")` designated profiles only.

## Usage

``` r
garry_daemons(
  read = NULL,
  compute = NULL,
  read_handles = NULL,
  gdal_config = TRUE,
  ...
)
```

## Arguments

- read:

  Read-pool daemon count; `NULL` (default) uses all logical cores. `0`
  tears the pool down.

- compute:

  Compute-pool daemon count; `NULL` (default) uses a third of the
  logical cores, capped at 8 with a floor of 2 (2 on CUDA: concurrent
  clients share one card). The compute pool's residual workloads (scans,
  big fused reductions) are compile-bound: every daemon that runs a scan
  task pays its kernel compile, so width multiplies compiles without
  adding admitted concurrency. Larger pools are SAFE at any width
  (per-daemon affinity masks and byte admission) and pay off for fleets
  of independent non-fusable tasks; they are an explicit choice, not the
  default. `0` tears down.

- read_handles:

  Open-handle cache depth on read daemons. `NULL` (default) uses
  `garry_opt("read_handles")`. Depth 1 suits per-slice mosaics that are
  rarely revisited (every open warped mosaic pins warper and connection
  memory); plans revisiting a few local multi-band files across many
  windows want a depth covering the interleaved file count, since
  closing a dataset discards its GDAL block cache.

- gdal_config:

  Apply
  [`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)
  on the host and read daemons (default `TRUE`). Set `FALSE` to leave
  session GDAL config untouched (e.g. when mixing local multi-file
  reads).

- ...:

  Passed to
  [`mirai::daemons()`](https://mirai.r-lib.org/reference/daemons.html)
  for both pools.

## Value

Invisibly, `list(read =, compute =)`.

## Details

You should not need to tune these. The cases for overriding: a source
API that throttles concurrent reads (smaller `read`); one daemon per
device on multi-GPU, or one per socket on NUMA (`compute`); a
memory-tight box (smaller `compute`, each daemon's base XLA client is
~300 MB once warmed).

It also applies the sensible defaults so a workload script needs no
preamble: the glibc `MALLOC_*` thresholds are exported BEFORE the
daemons spawn (read at exec, so children inherit them), and
[`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)
runs on every read daemon. Neither touches the host's own GDAL config
(that would hide local sidecars for the caller's reads); call
[`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)
yourself to tune host-side discovery. `MALLOC_*` is only-if-unset, and
`gdal_config = FALSE` skips the GDAL settings entirely.

## See also

[`garry_daemons_set()`](https://belian-earth.github.io/garry/reference/garry_daemons_set.md),
[`garry_pool_hygiene()`](https://belian-earth.github.io/garry/reference/garry_pool_hygiene.md),
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
