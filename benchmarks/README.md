# garry benchmarks

The reference workload is vrtility's median-composite benchmark
(`vrtility/benchmarks/`): HLS S30 from Planetary Computer over a PNG
bbox, all of 2023, Fmask bits 0-3 masked, warped to the EPSG:20255
30 m grid, temporal median, written to disk. The aim is parity with
Open Data Cube + dask; vrtility already beats it.

Numbers are network-sensitive: always compare runs from the same
sitting, against a vrtility baseline measured in that sitting.

## Results

2026-07-07 evening, stage-merge pass + decoupled reads (baseline
measured same sitting):

| pipeline | bands | wall time | fleet peak RSS |
|---|---|---|---|
| vrtility main (15 daemons) | 3 | 31.0 s | - |
| garry, fused plan (12 or 16 daemons) | 3 | 65.4 s | 6.9 GB |

Earlier same day, before the stage-merge pass (slower network hour):
vrtility 37.9 s, garry merged-plan-only 73.5 s. 2026-07-05, faster
connection: ODC + dask 28.4 s, vrtility 20.7 s, garry per-band
collects 131.7 s.

What the fused architecture changed: the planner's stage-merge pass
folds single-consumer compute chains into their consumers, so
mask -> stack -> median -> band stack runs as ONE XLA program per
chunk (172 members, zero intermediate store round-trips); the chunk
store is uncompressed (gzip cost hundreds of ms per chunk for
nothing); and read granularity is decoupled from compute granularity
(sources read whole windows once, split into per-compute-chunk store
files on write, so the compute tail parallelises and overlaps the
read drain without re-opening mosaics). Offline (local files) the
identical workload dropped 59.9 s -> 14-19 s.

Correctness: garry's B04 vs vrtility's agrees at correlation 0.992
(mean abs diff ~14 reflectance units; nearest-vs-bilinear tile
resampling and per-day-slice vs per-item stacking).

The remaining ~2x is isolated to the read path: 220 GTI per-slice
warped window reads take ~55 s of the 65 s wall (identical at 12 and
16 daemons, so throughput- not concurrency-bound), while vrtility
moves the same pixels in ~31 s total. Next lever (Phase 9
continuation): per-item reads with on-device mosaicking, or GTI read
tuning.

## Memory postmortem (2026-07-07)

The first merged-plan runs OOM'd a 62 GB machine. Root cause: stage
closures captured the whole 500-node graph (directly, and via user
mask-fn environments that referenced LazyRasters and through them the
graph again). One mask-stage closure serialized at ~117 MB; every
mirai task shipped one and every daemon retained a deserialized copy
per stage in its jit cache. Fixes, all in garry:

1. `.compose_stage_fn` extracts per-member specs and never captures
   the graph; user fns are rebound onto minimal environments holding
   only their free variables (`.slim_fn`, codetools). Stage closures
   are now ~300 KB.
2. The GDAL dataset handle cache is LRU-capped
   (`garry.handle_cache_max`, default 4) and closes evicted handles:
   open GTI warping mosaics pin warper + VSICURL + block-cache memory.
3. The benchmark exports `GDAL_CACHEMAX=256`: GDAL's block cache
   defaults to 5% of RAM PER PROCESS and every daemon inherits it.

With all three, the full three-band run peaks at 8 GB fleet-wide.

## Running

```sh
Rscript benchmarks/hls-median-composite.R 12 B04           # one band
Rscript benchmarks/hls-median-composite.R 12 B04 B03 B02   # full workload
```

Network required (Planetary Computer, anonymous + pre-signed hrefs).
The STAC query is untimed, matching the reference benchmarks. The
scheduler prints task progress (`options(garry.progress = TRUE)` is
set in the script); a three-band run is ~226 tasks (220 whole-window
GTI reads + the fused compute chunks).

Note on the vrtility baseline: `vrtility/benchmarks/benchmark_r_vrtility.R`
names a `vrtility_median` GDAL pixel function that is not registered by
any installed component (daemons fail with "read raster failed"; the
underlying GDAL error is "pixel function not registered"). The 37.9 s
baseline above was run from vrtility main with GDAL's built-in `median`
pixel function instead, host and daemons running the same installed
build.

## What the script shows about the API

- `stac_query()` -> `stac_sources()`: search results become a flat
  table (one row per item x asset); `stac_drop_duplicates()` /
  `stac_time_slices()` are plain-R table operations.
- `stac_gti_index()`: the table becomes a GDAL GTI tile index; each
  day is a `FILTER`ed mosaic of that index, pinned to the target grid
  via open options (mixed UTM zones are reprojected per tile by GDAL).
- `lazy_map(band, fmask, dtype = "f32", fn = ...)`: elementwise ops
  written in plain R with the `g_*` vocabulary; they trace into fused
  XLA kernels.
- `lazy_stack() |> reduce_over("median", "t", nan_rm = TRUE)`: the
  per-band composite; NaN is nodata everywhere (D8).
- `lazy_stack(composites, along = "band")` + one `collect(path =,
  distributed = TRUE)`: all bands in ONE plan -> one multiband GTiff.
  One scheduler queue keeps the network saturated across bands, and
  graph merge dedups the shared Fmask sources (read once, not per
  band).
