# GDAL multi-band fan-out: one entry point, no cptkirk

Date: 2026-08-12. Status: DESIGN AGREED (Hugh), implementation not
scheduled. Supersedes the cptkirk direction in
design/aef-multiband-read.md; the experiments below close that
investigation's open benchmark question.

## Decision

1. **cptkirk is removed entirely.** GDAL is the sole IO boundary, for
   multi-band remote COGs too. The measured basis is below: a mirai
   fan-out of band-partitioned GDAL reads matched or beat cptkirk in
   every regime tested, including cptkirk's best case (one async pool
   across many files x many bands).
2. **lazy_cog is removed with it, not rewired.** `lazy_dataset()` (and
   `lazy_source()` for a single file) is the one way into ANY source:
   COG catalogs, single multi-band COGs, Zarr via the GDAL driver,
   anything the driver layer reads. No per-format constructors. The
   engine picks the read strategy (band fan-out, raw fast path,
   warp-on-read) by inspecting the source, never by which function the
   user called. lazy_cog only existed to route to a second engine;
   with the engine gone the router is API noise. Pre-release, so no
   deprecation shims: it is deleted.

## Evidence (benchmarks/mb-read-bench.R, 2026-08-12)

Workload: real AEF annual embedding tile(s), 36S, source.coop, public.
8192^2 px, 64 Int8 bands, COG ZSTD, INTERLEAVE=BAND, 1024 px tiles.
Single-file test: one 2048^2 native window, all 64 bands (a 2x2 tile
window x 64 band planes = 256 scattered ranges: stock GDAL's worst
case). Every measurement in a fresh process (no vsicurl cache
carry-over); per-band checksums identical across every method in every
run, including the mosaic path.

| method | slow link | fast link | local (/dev/shm) |
|---|---|---|---|
| single GDAL handle | 29.6-64.7 s | 48.5 / 29.6 s | 1.65 s |
| GTiff NUM_THREADS=ALL_CPUS | 36.4-58.2 s | 35.1 / 38.1 s | 1.47 s |
| 8 mirai daemons x 8 bands, own handle | 23.4-30.9 s | **20.4 / 19.3 s** | 1.6-1.8 s |
| cptkirk ck_warp_to_buffer | 25.3-50.4 s | 40.5 / 24.2 s | 2.37 s |
| raw-BSQ .bin floor | | | **0.13 s** |

Multi-file: 2048^2 window straddling the corner junction of 4 adjacent
tiles (each contributes a 1024^2 quadrant, 64 bands) -- the real
acquire_aef shape, and cptkirk's best case (its runtime pools files
AND bands):

| method | reps |
|---|---|
| sequential GDAL, tile at a time | 171.1 / 126.9 s |
| cptkirk, ONE pool across 4 files | 30.8 / 29.9 s |
| cptkirk, called per tile | 153.6 / 136.6 s |
| mirai fan-out, 32 (tile x band-set) tasks over 8 daemons | **23.5 s** (one rep; other failed on a transient) |

### Mechanism

- **The single handle is latency-bound, not bandwidth-bound.** A
  band-interleaved window is hundreds of scattered tile ranges fetched
  sequentially through one connection; the fast link did not rescue it
  (48.5 s). More bandwidth never fixes a serial range walk.
- **Concurrency is the whole game, and it does not care who provides
  it.** cptkirk's async runtime and N independent GDAL handles on N
  mirai daemons are the same medicine. The fan-out was faster and far
  tighter-spread in every regime.
- **cptkirk has no decode-side edge.** Locally, plain GDAL beats it
  (1.65 vs 2.37 s), and garry's raw-BSQ staging is 12x under any tiled
  read -- so for anything read more than once, staging dominates and
  the staging is already GDAL-side.
- **Cross-file pooling is decisive** (cptkirk pooled 30 s vs per-file
  153 s) -- but task fan-out pools across files naturally: tasks are
  (file x band-chunk) pairs and the pool does not know the difference.

### Measured dead -- do not re-litigate

- GTiff `NUM_THREADS` open option: parallel tile DECODE, but range
  fetches still effectively serialize through the one handle. No
  reliable remote win (35-58 s), marginal local win (1.65 -> 1.47 s).
- GDAL multidim (mdim) for COGs: the multidim API cannot open a
  classic GTiff at all. Only relevant if data is restaged as Zarr,
  which is a storage decision, not a read lever.
- Handle sharing across daemons: impossible by construction (a GDAL
  dataset is a process-local pointer with its own connection state),
  and undesirable -- private handles ARE the concurrency.

## What already exists (the reason this is small)

- `gdal_read_window()` accepts a band VECTOR;
  `.gdal_read_window_bands` reads all requested bands of a window in
  one pass, slab-sized to the block cache so interleaved blocks
  decompress once, returning a (band, y, x) cube or rank-3 row-major
  raw f32 payload (gdal_adapter.R).
- `.daemon_run_source_shm` already handles rank-3 multi-band windows,
  producer-side part splitting, mori staging, and the raw f32 store.
- The raw-BSQ cube staging (`.stage_buffer`-style .bin + sibling
  VRTRawRasterBand .vrt) and its 12x read fast path are engine-level;
  cptkirk merely fed them. They stay verbatim.
- Reader pool, byte budgets, `garry.read_retry`, fail-soft nodata
  windows, handle cache, ABI guard: all reused unchanged.
- Fused dequant (`dequantize_aef` / `dequantize_esd` as lazy_map)
  rides the read exactly as today.

## The one genuine gap: task granularity

Today one source = one read task = one handle, and the multi-band
read walks its bands sequentially through it -- the losing shape
above. The change is a band-partition rule, in two seams:

1. **Discovery (lazy_dataset / lazy_source).** An asset whose file
   carries >1 band becomes N band-chunk sources over the same path.
   `SourceNode@band` is already `class_integer`; the read path already
   takes vectors. Chunk size: a `garry_options()` knob (working name
   `mb_band_chunk`, default ~bands/pool so one wave covers the file;
   one task per band is too fine past ~64 bands, whole-file too
   coarse). Band names ride from file band descriptions (the
   stage_raw_cube precedent: QA is found BY DESCRIPTION). The band
   axis assembles through the existing `lazy_stack(along = "band")`
   machinery -- `collect()` already builds band-major outputs.
2. **Fetch (pipeline route).** A band-chunked fetch task (sibling of
   `.daemon_fetch_window`) writes its chunk's plane run into a shared
   per-slice .bin: planes are contiguous in BSQ, so N writers hit
   disjoint offsets, then the raw fast path serves every downstream
   read. Same shape as `gd_strips`, rotated 90 degrees (bands, not
   rows).

Single-band sources and catalogs (HLS etc.) are untouched: band count
1 means the rule never fires and today's path runs byte-identically.

## Removal plan

| step | repo | work |
|---|---|---|
| 1 | garry | band-partition rule + band-chunk fetch; gates: fan-out == single-handle byte-identity on local multi-band fixtures; live AEF checksum vs GDAL reference |
| 2 | garry | delete lazy_cog.R + .ck_* machinery + cog_info dependency; metadata via the existing `/vsicurl` header open (the whole-file-download trap is only about UN-prefixed https URLs); cptkirk out of DESCRIPTION; test-lazy-cog.R re-gated as multi-band lazy_source/lazy_dataset tests (local tiled COGs keep it offline) |
| 3 | hutan | `aef_warp_ck()` deleted; `aef_warp()` (the gdalwarp twin that already exists beside it) or garry's fetch takes over; garry-engine.R refs go |
| 4 | ramet47 | acquire.R: `cptkirk::ck_warp` (ESD granules) and `hutan::aef_warp_ck` swapped for the GDAL path |

Sequencing: garry first; hutan/ramet47 keep working on cptkirk until
their step lands (same one-repo-at-a-time pattern as the garry-native
refactors).

## Risks and open questions

- **Sample sizes are small** (2-3 reps/regime) and cptkirk was erratic
  on the fast link; but the fan-out tied or led everywhere, so the
  plausible downside is parity, not regression.
- **Provider connection behaviour differs** (source.coop vs Azure MPC
  vs S3). The reader-count knob already parameterizes this; the chunk
  knob adds the second axis. Defaults need one calibration pass per
  major provider.
- **Per-task header opens**: each band-chunk task opens the file on
  its daemon (~0.5 s remote, once per daemon thanks to the handle
  cache). Amortized across a run; a fetch-window pre-open warm is the
  lever if it ever shows.
- **Error propagation**: one experiment rep died on a transient whose
  detail the harness swallowed. The integration inherits
  `garry.read_retry` + fail-soft, and must propagate mirai error
  values into the classed read errors (do not repeat the harness's
  `stop("worker failed")`).
- **Narrow band subsets are the least-parallel case**: per-band
  sources mean read concurrency = bands x coarse-splits, so selecting
  3 of 64 bands over a huge window runs ~6 tasks however wide the
  pool is (observed live 2026-08-12). If that shape ever matters, the
  lever is finer read granularity for wide windows
  (`garry.read_target_px`, already a knob), not reader machinery.
- **Zarr**: enters through the same door via the GDAL Zarr driver's
  classic raster model ((y, x, band)); the labelled-cube multidim API
  is a separate, later question (see write_zarr notes in
  ir-extensions-todo.md #10).

## What is lost with cptkirk

Honesty items, none blocking: an async reader with intra-file range
concurrency inside ONE process (garry replaces it with process-level
concurrency it already owns); raw-URL header reads without /vsicurl
(GDAL needs the prefix; garry controls its own URLs); and cptkirk's
obstore-side auth conveniences (garry's MPC signing and SAS re-sign
already cover the providers in use).
