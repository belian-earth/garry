# Deep review synthesis: why garry loses at cohort scale, and the path back

Date: 2026-07-20. Inputs: six independent subsystem reviews (this directory), each with file:line evidence and, where feasible, measurements against the working tree. Brief: `design/deep-review-handoff.md`.

## 1. Diagnosis

The bc-cohort predict fails on a chain of three multipliers, all rooted in one modelling decision: each band is its own `SourceNode`, so the plan has one read task per (band, window).

1. **Decompression amplification, measured at the band count.** A per-band read of a pixel-interleaved 1-row-strip DEFLATE file decompresses every band's strips and keeps one. Measured on a synthetic file built with garry's own writer defaults: 72 per-band window reads took 4.04 s where one band-blocked pass over all 72 bands took 0.13 s (31x; the per-band single read is 0.06 s, so amplification is the full band count). The belief that GDAL block cache plus window-major ordering keeps amplification near 1x is false at cohort scale: one window's all-band footprint is ~9.8 GB against a 256 MB per-daemon cache, and sibling band tasks scatter across 8 daemons with private caches. Ballpark for the cohort: ~114 TB of DEFLATE decode, roughly 3 hours of pure decompression across 8 readers. This is the explanation for run 5 (healthy CPU, far too slow).
2. **Task-count blowup is mathematically forced.** With per-band sources, read tasks obey `tasks >= 8 * n_src * n_in * grid_px / budget_bytes`, which at 145 bands is >= ~15k tasks at any window size (observed 24,610). Task count scales as bands squared. No tuning of `read_budget_mb` or window size escapes this; only moving the band axis out of the source count and into the region shape does.
3. **Host orchestration pays per task.** Each launch serializes a 333 KB `ChunkGrid` (99% S7 class definitions; payload ~1 KB) for reads and a 3.36 MB stage closure for computes (redundant: daemons already hold every distinct fn after the warm-up broadcast). Each drain sweep scans all remaining pending tasks (16.8 ms at 20k pending, ~O(n^2) over the run; the O(frontier) comment in the code is wrong). Streamed sink writes run on the host thread inside the harvest loop. Together these cap the host at tens of tasks/s, which the blowup in (2) turns into wall-clock.

The compounding structure explains the debugging history: each fixed defect exposed the next multiplier. Fixing any one layer is insufficient; fixing (1)+(2) at the source collapses (3)'s constant factor by two orders of magnitude as a side effect.

Everything the recent uncommitted work verified stays verified: the refcount/release machinery is sound (adversarially checked, no defect constructible), kernel trace/JIT caching is correct (one signature covers all 22 year-stages; compiles are not the bottleneck), D22 halo propagation is correct with no superlinear inflation, NaN/edge/nodata read semantics are correct, and graph construction is linear. The architecture problem is task granularity, not the store, not the JIT, not the IR.

## 2. The structural fix: multi-band read coalescing

Four reviewers converged on this independently (scheduler, read path, planner, gdal-direct), and the planner reviewer proved the IR admits it today:

- `SourceNode@band` is `class_integer` with no length validation; `output_grid` returns `node@grid` verbatim, and a `(band, y, x)` grid is exactly what `StackNode` produces. A ~30-line planner pass can `graph_replace` a `StackNode(along = "band")` whose parents all share path/open_options/grid with one multi-band `SourceNode` carrying the stack's node id; every consumer is untouched because stage exports are keyed by node id.
- The reader side needs: a read task that takes vector `band` and reads all bands per window (dataset-level RasterIO or a band-blocked row-slab loop through gdalraster; measured cache-independent), producing per-band elements of ONE shared region. The `parts`/`source_elts` machinery (scheduler.R:125-139, 803-841) already supports one region with many named elements; it extends from spatial parts to band parts.
- Bookkeeping corrections that must land with it: `store_mb` must count the band axis (scheduler.R:758-761 books 4 B/px for rank-2 only; a (145, y, x) region would be under-budgeted 145x); `.plan_read_px` must price bytes per (file, window), not per input node, which lets `read_target_px` stay large because one region for 145 bands costs the same residency as 145 regions but one decompress pass.

Expected impact: read tasks 24,610 -> ~220; store regions and host bookkeeping down ~100x; decompress CPU down ~100-150x; the read budget and the task count stop fighting. Design groundwork already exists in `design/aef-multiband-read.md` (option b: reader-side coalescing).

## 3. Priority plan

**P0 - one-line experiments before any surgery (validate the diagnosis on the real cohort).**
- Rerun with read-daemon `GDAL_CACHEMAX` raised to ~2 GB and `read_handles` raised to ~32, and full-width read windows if quick to force. If wall time collapses toward the projected ~20 min, the diagnosis is confirmed with zero code risk. Note the ceiling of this palliative: bands still scatter across daemons, so best case is ~n_daemon-fold amplification (~8x), not 1x.
- Instrument `task_log` write lines to size the host-thread sink-write stall (scheduler reviewer could not quantify it statically).

**P1 - the structural fix.** Multi-band read coalescing as in section 2. Largest single lever; attacks all three multipliers at once.

**P2 - host loop de-bloat (independent of P1, compounding with it).**
- Stop shipping the stage closure per compute task; daemons hold every distinct fn from the warm broadcast, so send the cache key with a resend-on-miss fallback (scheduler.R:906-917). Same for fused read fns (779-787).
- Replace the per-task `ChunkGrid` with a plain-list window spec or broadcast per-stage grids once (scheduler.R:779-787, 824-835). ~300x less launch serialization.
- Event-gated ready queue: push tasks when `dep_left` hits 0; skip the launch scan entirely on sweeps that harvested nothing (verified safe: slots, budgets and dep_left only change at harvest). Kills the O(pending) sweep.
- Move streamed sink writes off the host thread (dedicated writer daemon; the region name is already the wire format), gated on the P0 measurement.

**P3 - planner sizing and layout (small, composable).**
- Full-width row-band read windows when the source's native block spans the grid width (passes.R:742-756 currently bails to square windows; ~4-5x redundant strip decompression on its own).
- Per-source-stage `n_in` for `.plan_read_px` instead of the plan-wide max (the 145-input ESD stage currently shrinks the AEF arm's windows too).
- Apply the scheduler's consumer-index pattern to the four remaining quadratic scans in passes.R (D22 fixpoint, source-halo inheritance, exports pass, Phase A joinable-Find): ~7-20 s of plan time at production scale -> under 1 s.
- Fix the merge-pass barrier guard to check the producer stage for Reduce/Scan members rather than the consumed node's class, and cap merged fan-in (passes.R:328-334). One post-reduce map currently collapses the plan into a mega-stage: demonstrated 493,670 tasks vs 27,346 for the same pipeline. The production graph sits one construction detail from this cliff.

**P4 - stop minting pathological files.** Default multi-band sink creation options to `TILED=YES, BLOCKXSIZE=256, BLOCKYSIZE=256, INTERLEAVE=BAND, BIGTIFF=IF_SAFER` (gdal_adapter.R:272-284). garry's own writer produced the 1-row-strip pixel-interleaved layout that started this. Rewriting the existing esd cache remains Hugh's call; the default change stops the bleeding.

**P5 - correctness batch (independent of performance work).** See section 4.

**P6 - strategic: the two-executor question.** The gdal-direct reviewer recommends widening the direct path's whitelist toward the predict family (multi-export consultation in collect(), non-GTI local sources, custom reducers, band-axis reduces, unary pre-map chains; each individually small) rather than porting its buffer model into the scheduler, but its whole-run buffer lifecycle must be fixed first (fetches never freed until end of run; ~220 GB at cohort scale). The scheduler reviewer counters that with P1+P2 the general path's granularity problem disappears and region-per-task is defensible. Recommendation: do P1+P2 first; they are needed regardless and de-risk everything. Extend the direct path opportunistically afterwards if the general path still trails ODC-parity on reduce-shaped plans; do not run both efforts concurrently. Wire or delete the unreachable `.execute_gd_general` third variant either way.

**P7 - quality cleanups** (dead `pooled` branch, tempfile md5 -> in-memory hash, cat -> cli progress, stopifnot -> cli in public entry points, duplicated comments, draw() memoization, preview() footgun guard, dataset `[[` CSE). Low individually; the draw() and preview() items matter for debugging exactly these workloads.

## 4. Correctness defects found (all paths)

| # | Sev | Where | Defect |
|---|-----|-------|--------|
| 1 | high | composite_direct.R:261-278 vs 380-395 | Failed warp fetch silently becomes an all-NaN slice; `err` field is write-only; `garry.read_fail = "error"` ignored on the direct path. Transient IO failures at 2.4k fetches produce plausible composites with holes and no diagnostic. |
| 2 | high | passes.R:328-334 | Merge-pass barrier guard defeated by one post-reduce map; silent mega-stage collapse (18x task inflation demonstrated). |
| 3 | med | scheduler.R:620-625 vs executor.R:469-474 | Scheduler's `warp_only` drops the reference's sink-membership guard; a source that is itself a sink but otherwise consumed only by warp stages loses its read under `execute_plan_mirai`. Planner reviewer flagged the same hazard for non-primary sinks independently. |
| 4 | med | scheduler.R:744-753, 1181-1191 | Fetch-backed assemble tasks bypass the read-budget gate while still inflating `mb_read_resident`; latent OOM/trickle on remote plans. |
| 5 | med | scheduler.R:952 vs 963-978 | Budget decrements at queue time but physical free waits for the clock flush; shm high-water can exceed budget by a flush window. Force-flush on queued-drop bytes too. |
| 6 | med | scheduler.R:947-951 | host_keep regions permanently consume read budget; in-memory multi-export collects strangle the launch gate late in the run. |
| 7 | med | lazy_cog.R:279-282 | Pinned mosaics read uncovered area as 0, not NaN, when the source has no nodata sentinel (D8 divergence). |
| 8 | med | composite_direct.R:165-171 | Direct path assumes per-slice fn/mask homogeneity without checking; heterogeneous stacks silently compute slice-1 semantics. |
| 9 | med | composite_direct.R:161, 167 | Eligibility probing subscript-errors (instead of falling through) on mixed masked/unmasked stacks. |
| 10 | med | scan_kalman.R + passes.R:719-726 | Scan stages hold ~730 B/px live vs the chunk model's ~128 B/px; ScanNode needs to report its own bytes/px. |
| 11 | low | scheduler.R:207-209 | Daemon raw trim path lacks the negative-trim assert; raw OOB subsetting zero-fills silently (verified). Add loud assert. |
| 12 | low | preview.R:277-303 | preview() silently launches a full-resolution collect of the whole workload when sources lack RESX pinning. |
| 13 | low | dataset.R:215-219 | `[[` mints a duplicate StackNode per access; natural band math doubles compute. |

## 5. Verified sound (negative findings worth recording)

- Release/refcount machinery (task_ins/store_users/host_keep/drop-once): no constructible defect; duplicate deps, multi-consumer, streamed multi-export all consistent. No retry machinery exists, so no retry hazard.
- Kernel signature and JIT caching: content-addressed, custom fns included, one signature across the 22 year-stages, warm-up covers the modal shape. Tracing is not the bottleneck.
- `node_stage`/`consumers_of` index args: verified `identical()` to the old Find/Filter behavior, including fallback paths.
- D22 halo propagation: additive, no double-counting through reduce partials, ring recompute bounded.
- Read-path edge/nodata semantics: halo clamp, D8 NaN padding, edge re-masking, sentinel promotion, raw f32 gating, writeBin cast semantics all correct.
- Graph construction: O(1) insert, linear end-to-end, not a bottleneck. `mlp_project`: correct, 12.8 ms/chunk warm, not the bottleneck.
- Direct path D13 cleanliness, mosaic ordering, band order, NaN edges: no defect found.

## 6. Reviewer conflicts and resolution

- **Per-stage preallocated buffers** (handoff suggestion): rejected by the scheduler reviewer with a residency argument (a stage buffer pins a whole band until its last consumer retires); superseded by multi-band regions per (file, window). Adopted.
- **Cache/handles palliative vs structural fix**: the API reviewer proposes the GDAL_CACHEMAX experiment as potentially sufficient; the read-path reviewer shows the scatter across daemons bounds the win at ~n_daemon-fold amplification. Resolution: run it as P0 validation, treat P1 as the fix.
- **Converge vs extend executors**: direct-path reviewer says extend direct; scheduler reviewer says fix general-path granularity and keep the store model. Resolution in P6: sequence, do not parallelize.

## 7. Per-subsystem reports

`scheduler.md`, `executor-kernel.md`, `planner-ir.md`, `read-path.md`, `gdal-direct.md`, `api-periphery.md` in this directory. Experiment scripts referenced by the reports live in the session scratchpad and are reproducible from the descriptions (synthetic predict-shaped plans, pixel-interleaved DEFLATE read benchmarks, serialization measurements).
