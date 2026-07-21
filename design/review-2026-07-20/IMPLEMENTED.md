# Implementation status (2026-07-20, scan-node working tree, uncommitted)

All work below is verified by the full test suite (6405+ passing, zero
failures) and targeted new tests; measurements are from this machine.

## P0: palliative knobs (DONE)
- `garry.gdal_cachemax_mb` (default 256): GDAL block cache per read
  daemon, applied by `garry_gdal_config()`; shipped to read daemons at
  pool creation.
- `garry.read_handles` (default 1): read-daemon handle-cache depth;
  `garry_daemons(read_handles=)` now defaults from the option.
- Both let a cohort rerun test the cache/handles hypothesis without
  code edits: `options(garry.gdal_cachemax_mb = 2048, garry.read_handles = 32)`
  before `garry_daemons()`.

## P1: multi-band read coalescing (DONE; the structural fix)
- New planner pass `.collapse_band_stacks` (passes.R): a
  `StackNode(along = "band")` whose parents are single-band
  SourceNodes over the SAME file (path, open options, nodata,
  resampling, spatially identical grids) is graph-replaced in place by
  ONE multi-band SourceNode carrying the stack's node id and grid.
  Consumers untouched. Gated by `garry.read_coalesce` (default TRUE).
  Skips: sink stacks, warp consumers, non-2-D or multi-band parents.
- `gdal_read_window` accepts vector `band`: `.gdal_read_window_bands`
  reads every band of the window in cache-sized row slabs (each native
  strip/tile decompresses ONCE regardless of cache size), returning a
  (band, y, x) cube or rank-3 row-major raw f32 payload.
- Rank-3 support through the whole path: `.exec_read_padded` (halo
  pads spatial dims of a cube), `.sv_slicer` (band-plane window
  slices), `.daemon_run_source_shm` parts, `execute_plan`'s split
  branch.
- Sizing reworked in BYTES: `.plan_read_px` and `.stage_bytes_per_px`
  price each input's outer-dim product, so one 145-band input costs
  what 145 per-band inputs did (residency identical, task count not).
  `store_mb` on read tasks multiplies by the band axis. Warm-up
  dummies match the rank-3 input shape.
- Compute-on-read fusion excluded for multi-band sources (would move
  the plan's whole compute onto the lean read pool).
- Measured: 72-band pixel-interleaved DEFLATE window read 17.6x
  faster than 72 per-band reads at production cache pressure. On the
  exact bc-cohort predict geometry (145x13 + 64x9, 8820x2586,
  full-width strips): read stages 2461 -> 22, read tasks 14766 -> 132,
  total tasks 17502 -> 2868, plan time 3.3 s -> 0.4 s. Parity:
  coalesced == per-band == oracle byte-identical; distributed ==
  memory; new tests in test-band-coalesce.R.

## P2: host loop de-bloat (DONE)
- Compute tasks send the jit cache KEY, not the stage closure, when
  the warm-up broadcast covered the key on the compute pool (the
  145-input closure measured 3.36 MB/task). Cold-cache daemons raise
  `garry_jit_miss`; the host resends once with the closure. Read-pool
  spill launches always carry it.
- Launch scan skipped on sweeps that harvested nothing (launch state
  only changes at harvest; measured 16.8 ms/sweep at 20k pending).
- `.stage_kernel_sig` hashes in memory (`rlang::hash`) instead of a
  tempfile + md5sum round trip per call.
- `flush_drops` filters the store env with per-key `exists()` instead
  of `ls()` (which sorts all keys per flush).

## P3: planner sizing and layout (DONE)
- Merge-pass reduce barrier now checks the PRODUCER stage for any
  Reduce/Scan member, not just the consumed boundary node: one
  post-reduce map no longer collapses the plan into a mega-stage
  (was a demonstrated 18x task inflation; regression-tested in
  test-planner-scale.R).
- Full-width row-band read windows when a source's native block spans
  the grid width (DEFLATE strips decompress whole whatever the
  window; square windows re-decompressed every strip ~5x).
- Per-source-stage read windows: budgeted by each stage's OWN
  consumers' fan-in, not the plan-wide widest stage.
- Phase A: `closed` is an env, the joinable lookup is an inputs-keyed
  index (was O(nodes^2) at 2.5k per-band maps); finalise uses one-pass
  consumer/reference indexes for the exports pass, the D22 fixpoint,
  and source-halo inheritance (was three O(stages^2) scans, ~7 s of a
  7.5 s plan at 2.4k stages).
- `.stage_bytes_per_px` prices ScanNode working sets (~56 x T B/px of
  live f64 state cubes in kalman_llt) so scan chunks are not sized 6x
  over their true footprint.

## P4: sink writer defaults (DONE)
- `gdal_create_output` default creation options are now TILED=YES,
  256x256 blocks, BIGTIFF=IF_SAFER, and INTERLEAVE=BAND for
  multi-band grids. garry's own writer no longer mints the
  pixel-interleaved 1-row-strip files that caused the read
  amplification. Existing esd cache files unchanged (Hugh's call).

## P5: correctness batch (DONE)
- Direct path honours `garry.read_fail`: fetch errors caught in-task
  (`$err`, previously write-only) and transport errors both surface;
  "error" (default) aborts, "nodata" warns — no more silent all-NaN
  slices (composite_direct.R `.gd_fetch_errs`/`.gd_fetch_fail`).
- Direct path per-slice homogeneity enforced: slices with a different
  masked-apply fn or mask chain than slice 1 disqualify the plan
  (hash comparison) instead of silently computing slice-1 semantics;
  eligibility probing no longer subscript-errors on mixed
  masked/bare stacks.
- Scheduler: `warp_only` elision keeps sources that are themselves
  requested sinks (matches execute_plan); fetch-backed assembles are
  gated by the read budget (they pin read-store bytes); drops
  force-flush when queued bytes exceed 25% of the read budget (shm
  high-water bounded by budget + epsilon, not budget + flush window).
- `.sv_upload` asserts non-negative trims (raw OOB subsetting
  zero-fills silently).
- `.ck_mosaic_pinned` passes NaN vrtnodata for float sets with no
  sentinel (uncovered mosaic area no longer reads 0).

## P1b: coalescing through a per-band gate (DONE, 2026-07-20 late)

P1 as first landed did NOT fire on the production ESD arm, and the
"17,502 -> 2,868 tasks" figure quoted for it was measured on a
synthetic graph of BARE sources. The real graph is not that shape:
`hutan::predict_mlp_lazy` gated every feature band before stacking
(`feats <- lapply(feats, function(f) f + qa0)`), so the stack's parents
were MapNodes and `.collapse_band_stacks` (which requires bare
SourceNodes) skipped it. The AEF arm has no QA gate, so it coalesced;
ESD did not. Measured on the cache bench (crop=512): still 1841 tasks.

Two coordinated changes fix it:

- **garry `lazy_map` (lazy_raster.R)**: inputs normally share the whole
  grid; the one relaxation is that a purely spatial (y, x) input may
  join a cube input, so a per-pixel plane can be applied across a
  (t/band, y, x) cube. `fn` broadcasts it itself via `g_rep_t()`;
  nothing in the IR reshapes, and a plane on a DIFFERENT spatial grid
  is still refused. Tests: `test-map-broadcast.R`.
- **hutan `predict_mlp_lazy` (garry-engine.R)**: gate the CUBE after
  the stack instead of every band before it. `qa0` is 0 (keep) or NaN
  (drop) for all bands alike, so `stack(f_b + qa0) == stack(f_b) + qa0`
  broadcast -- identical values, very different plan.

Measured on a same-file 8-band fixture: source_read stages 8 -> 2,
tasks 9 -> 3, and per-band vs post-stack results byte-identical (max
abs diff exactly 0). Scaled to the ESD arm that is ~1752 source stages
(145 bands + QA, x12 years) -> 24.

This also targets the memory blowup below: with the gate per band, every
predict chunk fanned in 145 separate regions and uploaded 145 buffers;
coalesced it is ONE (band, y, x) region and one upload per year.

## P7: memory admission control (DONE, 2026-07-20 night)

The bc-cohort OOMs were not a leak: garry committed FIXED budgets and
launched as though it owned the machine. `ram_budget_mb x n_comp` is
9.2 GB of in-flight compute with an 18-daemon pool, plus a flat
`read_budget_mb`, decided before launch and never revisited -- while
the calling session already held ~9 GB and grew further mid-run.

- `execute_plan_mirai` now treats both budgets as CAPS and fits them
  inside `garry.exec_ram_fraction` (default 0.6) of what is actually
  available, **re-read every 5 s during the drain** so a host that
  grows while we run tightens the gates instead of racing the OOM
  killer. Floors keep progress possible (largest single compute task,
  one read window), so a tight budget serialises rather than
  deadlocks -- gated by a test that drives the fraction to 1e-6 and
  still gets identical results.
- Availability is `min(machine free, cgroup headroom)`.
  `/proc/meminfo` reports the HOST: inside a container, systemd scope
  or SLURM step it can read tens of free GB while the process is one
  allocation from its own limit, and budgeting on it overcommits
  straight into a cgroup kill. Verified: 57.5 GiB unconstrained,
  3.88 GiB inside a 4 GB scope. The machine figure comes from
  **memuse** (new Import, portable across Linux/macOS/Windows/BSD);
  the cgroup term is garry's own, since memuse does not model cgroups.
- A single chunk that cannot fit the whole budget is a PLANNING
  problem, so it warns with actionable advice (`chunk_target_px`,
  `ram_budget_mb`) instead of stalling mysteriously.

Tests: `test-mem-admission.R`.

## Result: the cohort bench now completes

`ramet47 pipelines/bc-cohort-si-bench.sh engine=garry crop=512
compute=2` (513x513, 12 ESD years + 9 AEF years, 16k shots):

| run | change | predict tasks | peak anon | outcome |
|-----|--------|---------------|-----------|---------|
| 2 | baseline | 1841 | 20.6 GB | OOM-killed, phase 7 |
| 4 | + coalescing through the gate | 125 | 19.5 GB | OOM-killed, phase 7 |
| 6 | + admission control, shot scope, band-name fix | 125 | 17.4 GB | **completed, 447 s, 13 rasters** |

Products are sane (SI_ensemble 13 bands, mean 3.51 m). si_tail's own
collect is 50 tasks. Peak remains high for a 0.26 Mpx crop and is worth
revisiting for the full cohort, but it no longer OOMs and now adapts
to whatever RAM is actually free.

## Open: predict-phase memory (investigation, evidence recorded)

The bc-cohort runs were dying of memory, and the cause is NOT where
earlier debugging looked (store residency / read budgets / daemon
fan-out). Measured with the cache bench at crop=512 (513x513 px, 0.26
Mpx) inside a memory-capped scope:

- The OOM victim is the HOST Rscript, not a daemon: kernel log shows
  `Killed process 711289 (R) total-vm:39082200kB, anon-rss:16799412kB`.
- An idle compute daemon with anvl/PJRT loaded is only ~0.15 GB, so
  the pool size is not the base cost.
- The climb happens during phase 5/12 (the predict collect), not
  si_tail: with compute=2 the scope was already at 8.3 GB anon while
  still draining predict tasks. Baseline peak 20.6 GB anon, OOM-killed
  at the 24 GB cap in phase 7.
- Standalone `si_tail` on synthetic 513x513 rasters, single-threaded,
  costs only ~0.55 GB / 8.7 s -- si_tail itself is not the problem; it
  inherits a host already carrying predict's footprint.

P1b is the first candidate fix (145 regions+uploads per chunk -> 1).
Re-measure with the bench before looking further.

## Not implemented (open, in rough priority order)
- Streamed sink writes still run on the host thread inside the
  harvest loop (P2d): instrument with task_log "write" lines before
  restructuring.
- Event-driven ready queue (dep_left -> ready bucket): the
  skip-scan-on-no-harvest gate removes most of the cost; full
  structure only if profiles still show scan time.
- Direct-path extension (P6 sequencing decision): multi-export
  consultation in collect(), non-GTI sources, custom reducers,
  band-axis reduces, unary pre-map chains — plus its whole-run buffer
  lifecycle fix first. Deferred until the general path's cohort run
  is measured with the above landed.
- Direct-path group overlap, `.execute_gd_general` wiring/deletion,
  `.gd_replay_mask`/.eval_node shared stencil, dead `pooled` branch,
  cat -> cli progress, stopifnot -> cli in public entry points,
  draw() memoization, preview() full-res guard, dataset `[[` CSE,
  graph_toposort quadratic form.
- Durable interleave fix for the EXISTING esd cache (rewrite as
  tiled INTERLEAVE=BAND): Hugh's call, invalidates the cache.
