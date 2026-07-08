# Phase 10: what odc-stac + dask do that garry doesn't (yet)

Source deep-dive of odc-stac, odc-loader, odc-geo, stackstac, and dask
core, plus same-sitting measurements. File:line references are
against these upstream commits (2026-07-08): odc-stac 9ebd9cd,
odc-loader b1007e9, odc-geo eefbada, stackstac 3857190, dask e0be880
— shallow-clone and `git checkout` these to line the refs up. The question driving it: ODC has always been a bit
faster than vrtility, and garry's network saturation is visibly lower
than both during a run.

## Measured context (same sitting, 2026-07-08 ~00:00)

| pipeline | wall | cgroup peak | bytes |
|---|---|---|---|
| ODC + dask (20-thread pool) | 35.6 s | 4.3 GB | 648 MB |
| vrtility main (15 daemons) | 33.2 s | 6.9 GB | - |
| garry (12 daemons, mori store) | 41.9 s | 10.4 GB | 649 MB |

Transfer volume is IDENTICAL. The isolated read drain is at the link
ceiling under every config tried (~23 MB/s that night; curl with 8
parallel streams managed 27 MB/s). Config levers measured dead on the
fleet probe: CPL_VSIL_CURL_CHUNK_SIZE=1M (worse: +63% overfetch,
1.8x slower), GTI NUM_THREADS=4 (no change), 24 daemons (no change,
per-read latency doubles: queuing). Daemon count, HTTP version,
multiplexing, and chunk size are all exhausted levers at native
resolution on this link.

## Why garry's average network saturation is lower

Not slower reads: garry's drain matches ODC's effective throughput.
The difference is duty cycle across the whole run. ODC's 20-thread
dask pool interleaves ~400 fine-grained read tasks with compute
continuously, so the pipe stays busy until the last seconds. garry
goes network-silent during: host graph build + plan (~3.5 s), the
LAST band's fused tail (~4.5 s; the first two bands' tails overlap
the drain since the reduce-join boundary), and the sink write. About
8-10 s of a ~40 s run at zero utilisation is exactly the observed
saturation gap and exactly the wall-time gap to ODC.

## Gap list (prioritised)

1. **Memory: 10.4 GB vs ODC's 4.3 GB.** Structural: 12 R+XLA daemon
   processes (each carrying an R session + PJRT runtime + GDAL
   caches) vs one process with 20 threads. Levers short of a
   re-architecture: bound XLA arena per daemon, drop GDAL_CACHEMAX
   further on daemons (reads are one-shot; odc sets VSI_CACHE=False
   for bulk reads on the same reasoning), fewer daemons once reads
   are latency- not concurrency-bound, eager shm release (done).
   Worth a dedicated session with per-daemon memory profiles.
2. **Serial host segments** (DONE 2026-07-08). Offline repro of the
   benchmark graph (3 bands x 55 slices): build 0.72 s -> 0.46 s,
   plan 1.29 s -> 0.34 s. The wins, in order: consumers index in the
   merge pass (was an O(stages) scan per candidate per fixpoint
   pass), `.stage_halo` all-zero fast path (was O(members^2) per
   attempted merge on a growing member list), bucketed source-dedup
   index in `graph_import` (was a linear scan of all sources per
   import), attr()-based node accessors on hot paths (S7 `@` is ~4x
   attr and was 38% of total).
3. **Last-band tail (~4.5 s): ACCEPTED after measurement.** The
   per-chunk cost is NOT extraction/upload: all 110 uploads take
   0.08 s and XLA dispatch is async, so ~0.6-1.5 s per 512^2 chunk
   sits in the nan_rm median execution (surfaces at g_download).
   Batching uploads into stacked (y,x,n) transfers measured NEUTRAL
   at best (host-side stack costs more than the saved per-call
   overhead). Parallelising the tail with finer compute chunks
   REGRESSES: offline benchmark-shaped run (local files, mori, 12
   daemons) walls 10.8 s / 14.0 s / 18.5 s at 2 / 12 / 30 sink
   chunks — per-chunk fixed costs (task launch, store parts, jit
   lookups, dispatch) beat the parallelism gain. Fewer/larger chunks
   remain optimal; the tail is the price of the last reduction.
   Jit warm-up during the drain remains REJECTED: mirai cannot route
   a task to a chosen daemon, so a warm task displaces a read for
   the length of a compile.
4. **Fail-soft reads** (DONE 2026-07-08): `garry.read_fail =
   "nodata"` fills a failed window with NaN instead of aborting the
   plan (odc `fail_on_error=False`, stackstac `errors_as_nodata`;
   both treat missing objects as expected in cloud archives).
5. **Retry cadence** (DONE): odc's 10 x 0.5 s + the timeouts odc
   omits (GDAL_HTTP_TIMEOUT=60, CONNECTTIMEOUT=10) in the benchmark
   env; consider making these garry-level defaults for vsicurl
   sources.
6. **Overview selection for coarse targets** (VERIFIED 2026-07-08).
   GDAL 3.13's GTI driver reads the matching overview when the
   pinned grid is coarser than native, in both the same-CRS and
   per-tile-warp paths — no open option needed (RESAMPLING is not a
   GTI open option; GDAL warns and ignores it). No garry change;
   gated by the poked-overview test in test-gti.R so a GDAL upgrade
   cannot silently regress A5-style coarse aggregation reads.
7. **Paste-vs-warp fast path** (DONE 2026-07-08). Two layers:
   same-CRS aligned GTI mosaic reads were already plain windowed
   reads (bit-exactness gated in test-gti.R), and `align()` now
   no-ops when the target grid is `grid_equal()` to the source's —
   previously it injected a WarpNode barrier (splitting the plan and
   routing through VRT warp machinery) even for the identity grid.
   Unlike odc's `ttol = 0.9`, only exact equality pastes: a
   sub-pixel-shifted paste moves every pixel up to half a cell.
   Gated in test-warp.R.
8. **Solar-day grouping** (DONE 2026-07-08).
   `stac_time_slices(granularity = "solar_day", lon = )` groups by
   local solar date (UTC + lon x 240 s, odc's rule); `lon` defaults
   to the circular mean of footprint centres, which resolves
   antimeridian AOIs correctly. `lazy_stac_stack()` passes `lon`
   through.
9. **Scheduler ordering** (DONE 2026-07-08). `.stage_launch_order()`
   (DFS postorder from the sink over stage inputs) now orders both
   executors: a consumer's whole producer subtree enqueues
   contiguously, sibling subtrees never interleave, so band k's
   fused tail overlaps band k+1's read drain by construction —
   an invariant (test-launch-order.R), not an accident of
   graph-build order. Also removed a latent scheduler hazard: task-
   table construction assumed producers were created before
   consumers, which fusion does not guarantee for split sources.
10. **Chunk byte budget.** dask targets 128 MiB per block and shrinks
    the SPATIAL extent (never time) when the stacked block exceeds
    it — same shape as garry's ram_budget px_cap. Validated; keep.

## Where garry is already ahead

- Handle cache (odc-loader's is an unimplemented TODO).
- Pre-signed hrefs (one token per collection vs per-URL signing).
- Shared-memory store (no disk round-trip; dask workers spill).
- Whole-window reads: no partial-tile overfetch; measured equal
  bytes to ODC's windowed reads.
- Fused XLA compute vs numpy per-chunk (and float32 NaN-sentinel
  convention matches odc's fast path).

## Benchmarking

`benchmarks/hls-median-composite-odc.py` is the ODC baseline (copied
from vrtility/benchmarks; needs a venv with the packages in its
imports — `uv pip install odc-stac odc-algo pystac-client
planetary-computer rioxarray distributed`). Note it does MORE work
than the R pipelines (morphological mask cleanup: opening 2 +
dilation 3) and still wins on wall time; when garry closes the serial
segments the comparison should be re-baselined with the same
morphology once garry has focal ops in the composite path.
