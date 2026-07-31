# Deep review 2026-08-02: synthesis

Three reports in this directory: `defaults-audit.md`,
`dead-pathways.md`, `refactor-map.md`. Charter (from the maintainer):
settle decisive defaults, remove pathways obsoleted by the
placement-pass progress (routed dispatch, raw cubes, hygiene), and
consolidate accreted structure. Evidence base: benchmarks/README.md
2026-07-29 onward; the both-mode-green suite is the safety net.

## Verdict

The engine's decisive era can be made official: routed dispatch
strictly dominates (399.8 vs 552.2 s at lower peak memory, both-mode
suite green), so the flip is justified, and WITH the flip the whole
legacy anonymous-pool apparatus — slow-start ramp, scan-compile
surcharge, pool-wide warmth, the <=2-pool warm-up gate — becomes
zero-coverage code and should be excised, not preserved (its admission
model was twice miscalibrated in the field; the structural K bound
replaced it). One real defect surfaced: the ABI skew guard never
enrolled composite_direct's five daemon entry points.

## Fix plan (ranked, dependency-ordered)

Wave 1 — decisive defaults + certain deletions:
1. Flip the routed default and EXCISE legacy mode: `garry_daemons()`
   always creates width-1 profiles; retire `routed_dispatch` and
   `scan_compile_mb`; replace the `cold_mb > 0` scan marker with an
   explicit task boolean (the excision trap dead-pathways flagged);
   delete ramp/surcharge/pool-warmth/warm-up-gate code paths.
2. Machine-derived compute default `max(2, min(cores %/% 3, 8))`
   (CUDA stays 2 — measured RESOURCE_EXHAUSTED at 2 sharing 4 GB);
   readers default `min(cores, 8)` (k=2 affinity floor oversubscribes
   past cores/2; r8 beat r10/r20 at scale). Fix the roxygen/code
   mismatch (docs already promise machine-derived sizing).
3. Delete the constant `pooled` flag + its unreachable arms and stale
   "single pool" comments; delete orphaned `.gd_compute_band`;
   simplify constant `.gd_pooled()`.
4. `gd_compute_budget` semantics fix: under defaults it is inert, and
   its documented fall-through ("the scheduler route") is wrong — the
   multi-band fall-through lands on gd_reduce. Make the budget guard
   the arm it can actually protect (the whole-grid single-process
   compute) and correct the doc. Latent risk closed: a heavy
   single-band composite currently runs whole-grid in the host with
   no size guard.

Wave 2 — the defect + consolidation:
5. ABI token: enroll composite_direct's daemon entry points (they are
   invoked cross-process via `garry::` but never hashed, so
   `.gd_daemon_prep`'s check passes under skew).
6. File split (pure moves): daemon.R (all daemon task bodies + ABI),
   pools.R (probes/profiles/affinity/garry_daemons), scheduler.R
   keeps execute_plan_mirai.
7. `.pool_broadcast()` consolidating the 9 profile-loop everywhere()
   sites; composite_direct dispatch rides it.
8. Dedup the host sink tail (scheduler.R ~2420-2496 mirrors
   executor.R 633-696) and port the scheduler's O(1) consumer index to
   executor.R's O(stages^2) warp_only scan.
9. options.R: merge the defaults list and `.garry_opt_info` into one
   table (two parallel 36-key structures).
10. Stale-comment sweep (top 10 from refactor-map: "Phase 5" in
    collect(), the pre-routed compute=2 rationale, the pre-mori file
    header, gdal_create_output's missing raw-branch doc, ...).

Deferred with reasons: error-idiom rewrite (105 unclassed cli_abort
sites nobody catches — define the rule, don't churn); test-suite
with_pools()/fixture consolidation (worthwhile, large churn — its own
pass); execute_plan_mirai admission-cluster extraction (most
entangled, weakest memory-behavior coverage); lazy_cog raw fast-path
extension to Int8/mosaic staging (feature, not cleanup); `read`
default A/B on a fast link before enforcing min(cores, 8) for the
composite fetch path.

CORRECTION 2026-08-02: item 2's reader default was enforced WITHOUT
the deferred A/B, and the A/B (run post-merge after a composite
regression report) reversed it: min(cores, 8) cost the HLS composite
23.2 -> 30.8 s (band drain 18.2 -> 26.0 s) — remote fetch is
latency-bound and wants width = cores; the r8-wins evidence was the
LOCAL raw-cube regime, where pipelines pin their own width
(build_si(readers = 8)). Default restored to all logical cores
(benchmarks/README.md).
