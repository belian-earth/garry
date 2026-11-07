# Set up split mirai daemon pools for distributed execution.

Two pools instead of one: `read` daemons execute source/warp read tasks
(and any kernels the placement pass fuses onto them), while `compute`
daemons run the materialised XLA stages. The resource model is: **pool
width is slots, admission is concurrency**. Every daemon is pinned to a
bounded, interleaved CPU mask at creation (`garry_opt("pool_affinity")`;
masks within a pool are mostly disjoint, while read and compute masks
overlap), so an XLA client created anywhere is narrow rather than
all-cores; the scheduler's live-RAM byte budgets decide how many tasks
are actually in flight; excess daemons idle lean. Called with no
arguments it sizes the pools to the CPUs this process may use: `read` =
one per CPU (remote fetch is latency-bound, so a wide read pool keeps
the network drain full) and `compute` = a third of them, capped at 8
with a floor of 2; on CUDA the compute pool is 2, since concurrent
clients share one card. On Linux those CPUs are the process's affinity
list, which a container's cpuset, a systemd scope's `AllowedCPUs` or a
`taskset` narrows, counted no higher than a cgroup CPU quota such as
`docker --cpus`; the masks name only CPUs on that list.
`collect(distributed = TRUE)` detects the pools automatically and
pre-compiles stage kernels on idle daemons at run start, scan kernels on
the `garry_opt("scan_profiles")` designated profiles only.

## Usage

``` r
garry_daemons(
  read = NULL,
  compute = NULL,
  read_handles = NULL,
  gdal_config = TRUE
)
```

## Arguments

- read:

  Read-pool daemon count; `NULL` (default) uses one per CPU this process
  may use. `0` tears the pool down.

- compute:

  Compute-pool daemon count; `NULL` (default) uses a third of those
  CPUs, capped at 8 with a floor of 2 (2 on CUDA: concurrent clients
  share one card). Scan tasks run only on the first
  `garry_opt("scan_profiles")` daemons, so width adds neither scan
  compiles nor scan memory. Larger pools are SAFE at any width
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
  on the read daemons (default `TRUE`). The host session's GDAL config
  is never changed; call
  [`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)
  yourself for host-side discovery. Set `FALSE` to leave the daemons on
  GDAL's defaults too (e.g. when mixing local multi-file reads). Either
  way every daemon's GDAL block cache is capped at
  `garry_opt("gdal_cachemax_mb")`: GDAL's own default is 5% of RAM per
  process.

## Value

Invisibly, `list(read =, compute =)`.

## Details

You should not need to tune these. The cases for overriding: a source
API that throttles concurrent reads (smaller `read`); one daemon per
device on multi-GPU, or one per socket on NUMA (`compute`); a
memory-tight box (smaller `compute`, each daemon's base XLA client is
~300 MB once warmed).

garry runs its own parallelism through these pools, so run one garry
session and let it use the machine. Wrapping garry calls in forked or
multi-process workers, such as
[`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html) or a
parallel `future` plan, is discouraged and at your own risk: GDAL, curl
and XLA hold state that does not survive a fork, and each worker's pools
would compete for the same cores, memory and `/dev/shm`.

It also applies the sensible defaults so a workload script needs no
preamble: the glibc `MALLOC_*` thresholds are exported BEFORE the
daemons spawn (read at exec, so children inherit them), and
[`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)
runs on every read daemon. Neither touches the host's own GDAL config
(that would hide local sidecars for the caller's reads); call
[`garry_gdal_config()`](https://belian-earth.github.io/garry/reference/garry_gdal_config.md)
yourself to tune host-side discovery. `MALLOC_*` is only-if-unset, and
`gdal_config = FALSE` skips the GDAL settings entirely, on every route.
Headers registered with
[`garry_http_auth()`](https://belian-earth.github.io/garry/reference/garry_http_auth.md)
are applied to the new pools.

Pools from an earlier call close first, and only once none of their
daemons is running a task, such as a read or a kernel warm-up: a pool
closed while a daemon replies can hang R for good, through a race in
NNG's IPC transport (fixed in NNG 1.12.5, not yet bundled in nanonext).
After three seconds garry names the pools it waits on and the daemons
still mid-task. A Ctrl-C, or a minute's wait, stops those daemons and
closes the pools; after a Ctrl-C
[`garry_daemons_set()`](https://belian-earth.github.io/garry/reference/garry_daemons_set.md)
is `FALSE` and no pool is started. A pool still mid-task with no daemon
garry can identify to stop, as on Windows, fails the close with a
`garry_pool_error`.

## See also

[`garry_daemons_set()`](https://belian-earth.github.io/garry/reference/garry_daemons_set.md),
[`garry_pool_hygiene()`](https://belian-earth.github.io/garry/reference/garry_pool_hygiene.md),
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
