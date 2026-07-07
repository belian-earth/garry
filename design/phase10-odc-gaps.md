# Phase 10: what odc-stac + dask do that garry doesn't (yet)

Source deep-dive of odc-stac, odc-loader, odc-geo, stackstac, and dask
core (2026-07-08, shallow clones at that date), plus same-sitting
measurements. The question driving it: ODC has always been a bit
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
2. **Serial host segments.** Graph build + plan ~3.5 s (S7 `@` and
   `%in%` dominate; planner passes are quadratic-ish over ~500
   nodes). Target < 1 s: cache node lookups in the merge pass, avoid
   repeated closure computation, profile-driven.
3. **Last-band tail (~4.5 s).** Cannot overlap reads (nothing left to
   read). Options: shrink per-chunk fixed cost (110 store
   extractions + uploads per chunk; batch upload into one stacked
   device transfer), or accept. Jit warm-up during the drain is
   REJECTED: mirai cannot route a task to a chosen daemon, so a warm
   task displaces a read for the length of a compile.
4. **Fail-soft reads** (DONE 2026-07-08): `garry.read_fail =
   "nodata"` fills a failed window with NaN instead of aborting the
   plan (odc `fail_on_error=False`, stackstac `errors_as_nodata`;
   both treat missing objects as expected in cloud archives).
5. **Retry cadence** (DONE): odc's 10 x 0.5 s + the timeouts odc
   omits (GDAL_HTTP_TIMEOUT=60, CONNECTTIMEOUT=10) in the benchmark
   env; consider making these garry-level defaults for vsicurl
   sources.
6. **Overview selection for coarse targets.** odc computes
   `read_shrink` and reads the matching COG overview explicitly —
   the single biggest bandwidth lever when target res is coarser
   than native. garry at native res never hits it, but A5-style
   aggregation workflows will. Verify the GTI driver picks overviews
   when the pinned grid is coarser (RESAMPLING open option +
   overview-aware RasterIO), and gate it with a test; if GTI
   doesn't, pre-select OVERVIEW_LEVEL per slice.
7. **Paste-vs-warp fast path.** odc pastes (plain windowed read, no
   warp) when CRS matches and alignment is within tolerance
   (`ttol=0.9` for nearest). garry's benchmark grid (EPSG:20255)
   forces per-tile warps of UTM sources — same as ODC's bilinear
   warp here, so no benchmark gap — but document and test the
   native-UTM-grid fast path for single-zone workflows.
8. **Solar-day grouping.** `stac_time_slices("day")` truncates UTC
   datetimes; odc groups by solar date at the geobox centroid
   longitude. Same result for HLS at 144E, wrong near the
   antimeridian. Add `granularity = "solar_day"` with a `lon`
   argument.
9. **Scheduler ordering.** dask orders tasks to minimise resident
   memory (dask.order: depth-first completion of a chunk's producers
   right before their consumer; LIFO ready stack with static
   priority tie-break). garry's insertion-order launch happens to
   match band order today, which is what makes the reduce-join
   overlap work — encode that as an explicit invariant (or a
   priority) rather than an accident of graph-build order, before
   plans get more complex (multi-composite joins).
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
