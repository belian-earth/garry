# Phase 9b session scope: the read path

## Goal

Close the remaining benchmark gap to vrtility on the HLS median
composite. As of 2026-07-07 evening (same sitting): vrtility main
31.0 s, garry 65.4 s for three bands. The gap is 2.1x and it is
entirely in the read phase.

Success gate: garry within 1.2x of a same-sitting vrtility baseline,
with correctness held at cor >= 0.992 vs the vrtility B04 composite
and fleet peak RSS under 10 GB.

## What is already settled (do not reopen)

- Stage-merge pass: mask -> stack -> median -> band stack runs as one
  XLA program per chunk. Guarded by test-stage-merge.R.
- Plan-wide chunking with index-aligned tables; halo-free source/warp
  stages read coarse (garry.read_target_px) and split into
  per-compute-chunk store files on write (producer-side).
- Uncompressed chunk store; LRU-capped GDAL handle cache;
  GDAL_CACHEMAX bounded per daemon; scheduler progress option.
- Memory is solved: 6.9 GB fleet peak on the full benchmark. The OOM
  root cause (stage closures capturing the graph) is fixed and gated.

## Measured facts driving this session

1. The 220 GTI per-slice warped window reads take ~55 s of the 65 s
   wall. Identical wall time at 12 and 16 daemons: the read phase is
   per-byte throughput-bound, not concurrency-bound.
2. Single-slice probe (warm): GTI open 0.1-0.2 s, full-window read
   0.2-0.9 s. Per-open cost is NOT dominant; my earlier assumption
   that it was led to a wrong config (do not repeat).
3. Windowed reads of warped mosaics amplify transfer: the 2-chunk
   config (440 half-window reads) cost +35 s over 220 whole-window
   reads. Warped reads decompress every intersecting source block
   regardless of window size. This is why reads are whole-window.
4. vrtility (main) moves the same source pixels in ~31 s total using
   per-item warped VRTs read block-wise on daemons, with the median
   computed as a GDAL pixel function during the read.
5. The compute tail is no longer on the critical path: ~6 fused chunk
   tasks finish within ~10 s of the last read, overlapped.

## Open question the session must answer first

Where do garry's extra ~25 s of read time go, given the same source
pixels? Measure before building. Candidates:

- H1 (GTI overhead): the GTI driver's per-read tile cull + per-tile
  warp costs more than a plain warped VRT read of the same item.
  Test: read one slice's window via GTI vs via
  gdal_warp_vrt()/autoCreateWarpedVRT on the underlying COG(s)
  directly; compare wall and transferred bytes.
- H2 (transfer volume): garry transfers or decompresses more bytes
  per slice than vrtility. Test: CPL_VSIL_SHOW_NETWORK_STATS=YES (or
  CPL_DEBUG curl request counting) on one slice read through each
  path; compare request counts and bytes.
- H3 (per-daemon HTTP config): multiplexing/chunk-size settings
  differ from vrtility's tuned defaults (see vrtility R/gdal-options.R
  for their measured-good set). Test: their config block verbatim on
  a garry read.

Decide the design AFTER these numbers exist.

## Candidate designs (choose by measurement)

Option B first (cheap): keep GTI sources, tune the read. Config
sweep on daemons; consider GTI RESAMPLING/NUM_THREADS and transformer
options. If H3 explains most of the gap, this may be sufficient.

Option A (structural, if GTI itself is the cost): per-item sources
with on-device mosaicking, vrtility's read shape with garry's compute
model:

- stac source table emits one SourceNode per item x asset (warped to
  the target grid via the existing warp machinery), instead of one
  GTI mosaic per day slice.
- Day-slice mosaicking becomes a fused kernel op: coalesce items
  within a slice by datetime order (first non-NaN wins, matching
  GTI SORT_FIELD semantics). Needs a g_coalesce op in R/ops.R (D9:
  traced nv_* dispatch + pure-R oracle) and a lazy_mosaic(xs) or an
  extension of lazy_stack semantics. The stage-merge pass then fuses
  mask -> coalesce -> stack -> median automatically.
- GTI stays as the user-facing mosaic layer (D18 unchanged); this
  only changes what the STAC composite helper builds internally.
- Watch: item count (98) vs slice count (55) raises source-stage
  count ~1.8x; whole-window reads of items covering half the bbox
  waste nothing (NaN outside footprint), but confirm transfer volume.

Out of scope this session: ergonomics (print/`[`/vignettes), bench
suite with regression thresholds, reflect/wrap focal boundaries,
rustac-r. Do not touch the decision register.

## Protocol (hard-won this week, follow it)

- Baseline vrtility in the SAME sitting before quoting any garry
  number. Use the scratch-installed main build with GDAL's builtin
  "median" pixel function (the repo benchmark script names a
  vrtility_median pixfun that nothing registers; see
  benchmarks/README.md).
- Contain every full benchmark run:
  systemd-run --user --scope -q -p MemoryMax=28G. Three OOMs killed
  the IDE before this rule existed.
- Iterate offline first: the offline repro (local files, distinct
  nodata per slice to defeat source dedup) runs the full plan shape
  in ~15-19 s and catches structural regressions without network.
- Reinstall garry (R CMD INSTALL) before any mirai run; daemons use
  the installed package.
- garry.progress = TRUE on anything long; silence reads as a hang.
- Gates before commit: full testthat suite, R CMD check clean,
  correctness cor >= 0.992 vs vrtility composite, fleet peak RSS
  from the sampler in the run log.

## State pointers

- Branch: claude/lazy-array-raster-design-eq2nZ, HEAD = stage-merge
  commit (planner pass, read decoupling, uncompressed store).
- Benchmark: benchmarks/hls-median-composite.R (progress on,
  GDAL_CACHEMAX=256, GDAL_INGESTED_BYTES_AT_OPEN=32768 already set).
- Results log and gap analysis: benchmarks/README.md.
- vrtility baseline script (patched, working):
  scratchpad from the previous session is gone after reboot; rebuild
  from benchmarks/README.md notes: install vrtility main to a scratch
  library, host AND daemons on that build, pixfun = "median",
  config_options with relaxed LOW_SPEED watchdog.
