# garry benchmarks

The reference workload is vrtility's median-composite benchmark
(`vrtility/benchmarks/`): HLS S30 from Planetary Computer over a PNG
bbox, all of 2023, Fmask bits 0-3 masked, warped to the EPSG:20255
30 m grid, temporal median, written to disk. The aim is parity with
Open Data Cube + dask; vrtility already beats it.

Numbers are network-sensitive: always compare runs from the same
sitting, against a vrtility baseline measured in that sitting.

## Results

2026-07-07 night, graph-build fix (declared-grid sources; two
interleaved runs each, same sitting):

| pipeline | bands | wall time | fleet peak RSS |
|---|---|---|---|
| vrtility main (15 daemons) | 3 | 34.9 / 36.6 s | - |
| garry, fused plan (12 daemons) | 3 | 42.1 / 41.1 s | 8.1 GB |

The ratio is 1.12-1.21x (mean 1.16x), meeting the Phase 9b gate of
1.2x. Both pipelines transfer the same volume (garry 646 MB, vrtility
688 MB) and the residual difference is garry's serial tail: compute
chunks can only start once every source read has landed (a fused
chunk needs every source's store split), so the last ~5.5 s of XLA
median plus ~3.5 s of host-side build/plan sit after a read drain
that already runs at the link's parallel ceiling. vrtility overlaps
its median (a GDAL pixel function evaluated during the read) with the
drain, paying nothing extra. See "What the 2.1x actually was" below.

Earlier 2026-07-07 evening, stage-merge pass + decoupled reads:
vrtility 31.0 s, garry 65.4 s (6.9 GB). Earlier same day, before the
stage-merge pass (slower network hour): vrtility 37.9 s, garry
merged-plan-only 73.5 s. 2026-07-05, faster connection: ODC + dask
28.4 s, vrtility 20.7 s, garry per-band collects 131.7 s.

## What the 2.1x actually was (2026-07-07 night)

The phase 9b session scope hypothesised the 2.1x gap lived in the
read path (H1 GTI driver overhead, H2 transfer volume, H3 HTTP
config). Measurement refuted all three:

- H1: a slice window read via GTI vs per-item warped VRTs of the
  underlying COGs is 0.9 s vs 1.5 s per slice; GTI is FASTER (and
  per-item reads fetch overlap regions twice).
- H2: identical transfer (~643 MB) across GTI/per-item and both HTTP
  configs, at matching wall times.
- H3: the benchmark's 220-read fleet workload runs in 32 s under
  garry's env, vrtility's env, and garry-minus-HTTP/2, identically.
  Single-stream throughput to MPC is ~5 MB/s; 8 parallel streams
  reach ~27 MB/s; 12 daemons aggregate ~20 MB/s. The drain is at the
  link ceiling; daemon count (12 vs 16) and config move nothing.

The actual gap was on the host, before any read: each of the 220
`lazy_source()` calls opened its GTI slice mosaic to discover
metadata, and the GTI driver satisfies that by opening one remote COG
per open (~0.1 s x 220, serial). Another ~3.6 s went to
`stac_gti_index()`: PROJ re-selects coordinate operations per bbox in
`transform_bounds()` (~7 ms x 98 rows x 4 assets) and per-feature
GPKG writes. Fixes, in garry:

1. `lazy_source(grid =, block_dim =)` declares the source's grid and
   skips discovery; the STAC layer probes metadata once per asset
   (4 opens instead of 220) since every slice of an index shares it.
2. `stac_gti_index()` transforms only unique footprints (HLS items
   sit on 2 MGRS squares, so 98 transforms collapse to 2) and writes
   FlatGeobuf instead of GPKG. 3.6 s -> 0.1 s.
3. `options(garry.task_log = <path>)` makes the scheduler log
   per-task launch/done timestamps; the decomposition above came from
   it and it stays for future profiling.

Chunk-count experiments (6 x 512 px vs 12/20 smaller chunks) showed
the fused tail is dominated by per-chunk fixed costs (220 store-file
reads + uploads per chunk, plus per-daemon XLA compile), so fewer,
larger chunks win; `chunk_target_px = 1.4e6` stands.

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

Remaining levers, in order of size: overlap the fused tail with the
read drain (needs per-chunk read completion, which the whole-window
read model deliberately avoids); trim the ~2.4 s of graph build +
planner passes (S7 `@` and `%in%` dominate the profile); faster
storage for the chunk store splits. All are second-order next to the
read drain, which is bandwidth-bound.

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
