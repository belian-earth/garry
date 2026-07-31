# Deep review hand-off: garry performance, scalability and correctness

Date: 2026-07-20. Branch: `scan-node` (uncommitted scheduler work in `R/scheduler.R`, `R/executor.R`, `R/passes.R`, `R/options.R`, new `tests/testthat/test-read-budget.R`). This report briefs a review of the whole package. The trigger is a concrete failure: the package cannot yet complete a real production workload competitively, despite winning every synthetic benchmark it was designed against.

## 1. What garry is

garry is a lazy raster engine for R. Users build an IR (a DAG of `Node`s over a georeferenced grid: sources, elementwise maps, focal ops, axis reductions, scans), and `collect()` plans and executes it. Compute kernels are traced through anvl to PJRT (XLA) or run as plain R; data moves through mori POSIX shared-memory regions between daemons. Three execution paths exist:

1. `execute_plan` (`R/executor.R`): single-threaded, in-memory. The semantic reference; everything else must match it (tests assert equality or 1e-6 tolerance).
2. `execute_plan_mirai` (`R/scheduler.R`): the general distributed path. Builds a task table (read tasks + compute tasks + sink writes), launches onto two mirai daemon pools (`garry_read` lean, `garry_compute` with anvl/PJRT loaded), drains with a polling loop, passes chunks via mori shm.
3. gdal-direct (`R/composite_direct.R`): a whitelisted fast path for reduce-structured graphs (composites, ndvi and similar via `.gd_decompose`). Warps f32 straight into pinned buffers, fetch-ordered pipeline, raw `mirai()` dispatch. This path reached ODC parity (3-band morphological composite 17.5 s; ndvi 11.97 s vs ODC 12.64 s).

Key point for reviewers: the fast path and the general path are different architectures. Every production failure below happened on the general path. The general path processes per-band, per-window, per-stage tasks through a host-orchestrated polling scheduler; the direct path streams warped windows into preallocated buffers with minimal host involvement.

## 2. The failing workload

The bc-cohort VM0047 SI pipeline (external packages hutan branch `garry-engine`, ramet47 branch `garry-si`) runs `build_si(engine = "garry")`. Its predict step is one multi-export `collect()`:

- Grid 2586 x 8820 (22.8 Mpx), f32.
- Inputs: ESD embeddings, 145 bands x 13 years, plus AEF 64 bands x 9 years. Each year is a separate multi-band GTiff addressed through per-band `lazy_source` nodes and VRTs.
- Structure: per-year `lazy_stack` -> `reduce_over` with a custom fn (`mlp_project`, an MLP forward pass) -> further maps; two arms (ESD and AEF); ~2.2k source stages, ~22 wide compute stages (up to 145 inputs each), and after read-window shrinking roughly 17k to 21k tasks.
- Source files are PIXEL-interleaved DEFLATE GTiffs with 1-row strips (written by `hutan::embed_read`). A single-band read therefore decompresses all 72 bands of its strip; only GDAL block cache and window-major scheduling keep amplification near 1x.

History of attempts on this workload, all on the general path:

| Run | Outcome | Root cause found |
|---|---|---|
| 1 | OOM | Read regions never byte-budgeted; ~210 GB projected residency (145 whole-grid windows x 22 year-stages). |
| 2 | OOM | Compute outputs never released mid-run; streamed sink chunks and cross-stage intermediates pinned to end of run. |
| 3 | Crawl, >1 h stuck, host 166% CPU, daemons idle | Host `gc()` every harvest sweep; `all(deps %in% done)` readiness O(tasks^2); band-major launch order + byte gate = serial trickle. |
| 4 | Crawl from the start, zero CPU anywhere | Task-table build itself: named-list `[[<-` insert is O(n^2) (profiled 326 s in `add_task`); O(stages^2) `Filter`/`Find` scans in `warp_only`, fuse eligibility, `.exec_split_cg`, `.exec_in_meta`. |
| 5 (2026-07-20) | Ran with healthy CPU but "far too slow"; Hugh reverted to `engine = "hutan"` to get the job done | Not yet diagnosed. This is the open question. |

All four diagnosed defects are fixed in the uncommitted working tree (read budget + refcounted release + `host_keep`; gc throttle; reverse-dep index + launch cursor; env-based task table + one-pass consumer/producer indexes). Entry-to-first-launch went from 326 s+ to ~50 s; synthetic drain rate went from 1.9 to 16.3 tasks/s with 8 read daemons. The full test suite is green. And it is still not fast enough. Four consecutive scaling defects in one code path, each only visible at the next scale step, is the evidence that this needs architectural review rather than more spot fixes.

Baseline to beat: the legacy hutan engine completes the same cohort (wall time in hutan `experiments/` logs). On a smaller vm47 tile the garry engine measured 282 s vs 550 s legacy with NaN-identical output, so the engine can win when the plan is small; it loses at cohort scale.

## 3. Where the review should dig

Ordered by suspected leverage. These are hypotheses, not conclusions; treat them adversarially.

### 3.1 Task and store granularity (scheduler + planner)

One task per (stage, window) and one mori region per task output means ~20k tasks and ~20k region create/write/map/unlink cycles orchestrated by a single-threaded R host loop. At 16 tasks/s the host is the ceiling; 20k tasks is 20+ minutes of pure orchestration even with perfect daemons. Questions: can reads be batched (one task reads all bands of one file for one window, N store regions or one strided region)? Can the per-window fan-in (145 read regions -> 1 compute) become a single gather task? Is the polling drain loop (`mirai::unresolved` sweeps) the right shape versus `mirai::call_mirai`/promises or a dispatcher-side completion queue? What is the actual per-task host cost budget (harvest, refcount decrement, flush bookkeeping, progress)?

### 3.2 Per-band source modelling (IR + read path)

The IR models each band as its own `lazy_source` node, so a 145-band year becomes 145 read tasks per window against a pixel-interleaved file. Even with the block-cache mitigation this multiplies task count, store regions, and host bookkeeping by the band count. A multi-band source node (one node, one read, one `[bands, y, x]` region) would shrink the predict plan by roughly two orders of magnitude in task count. Related: `design/aef-multiband-read.md` (paused) already scopes fast multi-band COG reads. Check what the IR, planner, `.exec_in_meta`, and kernel signatures would need for band-blocked sources, and whether `lazy_stack` of same-file bands can be collapsed automatically.

### 3.3 General path vs gdal-direct architecture

`.gd_decompose` proves the decompose-to-direct approach works and wins benchmarks. The predict graph (stack -> reduce_over(custom fn) -> maps) is reduce-structured; why does it not qualify for the direct path, and what would extending the whitelist cost? Alternatively, port the direct path's virtues into the general path: fetch-ordered dispatch, preallocated per-stage buffers instead of per-task regions, warp-on-read. Review `composite_direct.R` and `scheduler.R` side by side for consolidation opportunities; two divergent executors is itself a maintenance and correctness risk.

### 3.4 Scheduler correctness under the new machinery

The uncommitted release/budget machinery is young. Audit: refcount correctness (`task_ins`/`store_users`/`host_keep`) under failure/retry paths, duplicate deps, multi-consumer stages, and streamed multi-export sinks; the launch gate (`read_ok`) for deadlock (budget below one window set is tested, but interleavings with compute-pool backpressure are not); `flush_drops` throttling vs shm high-water mark; `first_pending` cursor vs out-of-order state changes; `.plan_read_px` window sizing interacting with task-count blowup (the budget fix 4x'd task count, trading OOM for host overhead; is there a window size that satisfies both?).

### 3.5 Planner quality (`passes.R`)

Stage merging, fusion eligibility, chunk sizing (`.chunk_for`, `read_target_px`, `chunk_target_px`), D22 halo propagation (padded exports, ring recompute), compute-on-read placement (`warp_only`). Look for: missed fusion (map chains that should be one stage), redundant recompute from halo rings, chunk sizes tuned for small plans that misbehave at 2.2k stages, pass-ordering issues, and remaining quadratic scans (the recent fixes indexed the scheduler's uses; the passes themselves may still scan).

### 3.6 Executor kernel path (`executor.R`, `ops.R`)

`.compose_stage_fn`, `.slim_fn`, tracing/JIT caching (`.stage_kernel_sig` collision risk for custom fns was fixed for ReduceNode/ScanNode; verify coverage), per-chunk anvl trace vs cached executable reuse, f32/f64 casts, NaN semantics (nan_rm, D22 edge re-masking). Custom-fn kernels (`mlp_project`) run per chunk: is the trace cached across chunks and daemons, or re-traced?

### 3.7 The rest of the package

`dataset.R`/`stac.R`/`lazy_raster.R` API layer (correctness of grouping, band harmonization, graph growth patterns that inflate node count), `gdal_adapter.R`/`lazy_cog.R` (read efficiency, VRT handling, config options passed to GDAL), `grid.R`/`chunk_grid.R` (geometry math), `graph.R`/`node.R` (S7 overhead on hot paths; property access cost showed up in profiles), `preview.R`, `gradient.R`, `scan_kalman.R`, `band_mlp.R`, `collect.R`, `options.R`. Lower priority but in scope; cheap wins and latent bugs welcome.

## 4. Constraints and ground rules

- Correctness bar: `execute_plan_mirai` and gdal-direct must match `execute_plan` (byte-identical where asserted, else 1e-6). The test suite (`devtools::test()`) is the gate; it is currently green.
- Locked design decisions D1-D22 live in `design/` (notably `halo-propagation.md`, `multi-export-collect.md`, `phase12e-overlap.md`, `scan-node-design.md`). Do not silently revisit them; flag if one is the obstacle.
- garry is consumed as an INSTALLED package by hutan and by daemons; scheduler changes need `devtools::install()` to take effect in the pipeline.
- All user-facing messages use `cli`.
- No pushes, no PRs, no commits without Hugh's explicit say-so. Work stays local.
- External context (hutan, ramet47) is read-only background for this review; the review targets garry itself. The interleave problem could also be fixed upstream (write embed_read outputs tiled INTERLEAVE=BAND), but that invalidates a large on-disk cache and is Hugh's call, not the review's.

## 5. What a finding should look like

For each finding: file:line, category (correctness / performance / architecture / simplification), the defect or opportunity stated in one sentence, evidence (code path, complexity argument, or measurement), proposed change, and expected impact at bc-cohort scale (2.2k stages / 20k tasks / 22.8 Mpx / 145 bands). Rank by leverage on the failing workload first, general quality second.
