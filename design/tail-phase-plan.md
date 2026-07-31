# Tail phase plan: point-fit cache, retained scan memory, routed dispatch

Date: 2026-08-01. Successor to the deep-review roadmap
(`design/deep-review-2026-07-31/SYNTHESIS.md`, all tiers landed) and the
tail-squeeze probes (`benchmarks/README.md` 2026-08-01). Target
workload: SI crop=2048, currently ~620 s (sitting-adjusted; best
recorded 576.2 s), decomposing as ~185-225 s predict, ~1 s calibrate,
~126 s host point fits + ~288 s garry drain (tail), ~15 s
validate/write.

## Evidence base

| Fact | Source |
|---|---|
| Tail drain = ~800-900 s of compute over 2 daemons; median scan chunk 3-4 s; compiles ~20-25 s / ~0.7-1.0 GB (loop-lowered) | task-log stage table + RSS samples, 2026-08-01 |
| Width 4 OOMs a 42G scope at ~38.5 GB: each scan-running daemon RETAINS ~6.5 GB (reusable XLA pool) | probe B |
| CUDA (A1000 4 GB): compute=2 exhausts the card; compute=1 completes at 2.8x SLOWER total | probes C |
| Width-1 mirai profiles: exact daemon identity at +12 us/task; directed warm routing 0.41 vs 1.68 s on the toy shape | design/width1-routing-spike.md |
| Host point fits (Kalman hyperparameter MLE + tau_break at GEDI shots) ~126 s single-threaded R, identical in both engines | build_si decomposition |

Conclusion ordering the work: the tail is WIDTH-bound, and width is
RETAINED-MEMORY-bound. Memory first, then routing makes width usable,
while the point-fit cache pays immediately in every sweep iteration.

## Workstream A — point fits (hutan/ramet47 ledger)

- **A1 (landed 2026-08-01):** `build_si(smoother_cache=)` caches
  `{hyperparams, break_scale}` like `fit_cache`; the bench wires it
  under the existing `fitcache=1` flag (`smoothcache-*.rds`). First run
  pays the MLE; later runs load it. Expected: ~100 s off every sweep
  iteration, both engines.
- **A2:** parallelise `.fit_global_kalman_hyperparams`'s objective —
  the per-sample KFAS filter loop is embarrassingly parallel
  (`mclapply` over series, chunked). Expected ~5-8x on the bench boxes
  for the cold fit.
- **A3 (stretch):** evaluate the MLE likelihood batched on device via
  garry's `kalman_llt` (needs a log-likelihood accumulator output on
  the scan and a KFAS-parity gate; the Q-timing and diffuse-init traps
  are already catalogued in the scan-node design). Only worth it if
  cold fits stay on the critical path after A1/A2.

## Workstream B — the retained scan working set (the width wall)

Goal: understand, then shrink, the ~6.5 GB a compute daemon retains
after running scan chunks. Success reopens width 4-6 inside 42G;
failure still yields an honest admission model (price the floor).

Characterisation experiments (one instrumented session, half a day):

- **B-E1 growth curve:** one compute daemon, run the SI tail's scan
  chunks sequentially; sample `RssAnon` after every chunk. Does
  retention plateau at one working set (allocator pool, reusable) or
  step up per KERNEL (accumulating executables/buffers)? The task-log
  rss stream already provides this; add per-chunk resolution.
- **B-E2 cache eviction:** after a scan stage completes,
  `everywhere({rm(.daemon_cache entries); gc()})` — does anon drop?
  Separates R-side jit-handle retention from native allocator pools.
- **B-E3 allocator trim:** explicit `malloc_trim(0)` on the daemon
  (small helper; `MALLOC_TRIM_THRESHOLD_` is already exported but only
  covers free() paths). Measures glibc-arena vs XLA-allocator split.
- **B-E4 buffer audit:** count live PJRT buffers per daemon via anvl
  introspection (may need a small anvl branch — development only, no
  push, per the review protocol).
- **B-E5 client recycle:** destroy/recreate the XLA client between
  scan stages; measures the true floor and the recreate cost (~3 s).
  Guard: the known XLA teardown segfault (benchmarks/README spike A).

Ship list, contingent on findings (in likely order of effect):

1. Scan-pool cache hygiene: evict scan executables per plan/stage when
   the pool is scan-shaped (`.comp_pool_shape` already knows).
2. Post-scan allocator trim hook on compute daemons.
3. anvl buffer-donation for scan inputs (upstream patch, if the PJRT
   pool dominates).
4. If nothing trims: a `scan_resident_mb` admission term per
   scan-running daemon, so wide pools are refused honestly instead of
   OOM-killed (the width-4 probe's failure mode).

Exit criterion: warmed scan daemon <= ~3 GB (width 4 fits 42G), or a
documented floor priced into admission.

### B outcome (2026-08-01/02)

Characterisation ran (`benchmarks/scan-retention-spike.R`): same-kernel
reruns plateau; distinct kernels accumulate ~60-90 MB each; of a 904 MB
standing daemon, 475 MB was trimmable glibc arena and 72 MB evictable
jit handles. SHIPPED: `src/trim.c` + per-task `malloc_trim`,
`.daemon_hygiene(deep=)`, run-start hygiene broadcast,
`garry_pool_hygiene()` — idle standing state 904 -> 557 MB across the
kernel sweep at zero wall cost.

The width-4 SI validation still died at ~38.9 GB, and its task-log
attribution reframes the wall: at kill the fleet held 22 GB LIVE
(compute daemons at 7.5 / 6.2 / 5.8 GB, one PEAKED at 11.8 GB during
its cold scan window) against 1.3 GB modelled. Three conclusions:

1. The wall is the LIVE scan working set during execution, not the
   idle retention the trim addresses. The SI robust smoother's cold
   window costs ~6-12 GB per daemon — the briefly-shipped
   `scan_compile_mb = 1500` (calibrated on the too-light synthetic)
   let three such scans launch in one refresh window; restored to
   10000 (c385b70). The surcharge prices cold LIVE working set and is
   workload-dependent; per-kernel measurement-driven pricing (the task
   log now supports it) is the follow-up.
2. Anonymous pools ROTATE scans across every daemon, so even
   serialised scans grow every daemon to the scan working set. Width
   confinement is an IDENTITY problem: workstream C is upgraded from
   "fixes compile multiplication" to "confines scan memory to K
   designated daemons" — the primary lever for wide pools.
3. Box safety: this is a 62 GB laptop; MEMMAX=42G left too little for
   the desktop and a run at the ceiling took the session down
   (systemd-oomd pressure kill). Cap MEMMAX at 24-32G here; wide
   sweeps belong on the bc-cohort box.

## Workstream C — width-1 routed dispatch (spike is GO)

Design sketch (scheduler-scoped; option-gated):

- `garry_daemons(read, compute)` with `garry.routed_dispatch = TRUE`
  creates the compute pool as N width-1 profiles `garry_comp_<i>`
  (probe `dispatcher = FALSE` first — width-1 profiles without
  dispatchers would make the fleet LIGHTER than today's pool).
- Scheduler state becomes per-profile: inflight slots (depth 2),
  `warmed_ck` sets, pids/affinity masks. `everywhere()` sites (option
  ship, ABI check, shm clear, warm-up) loop the profiles.
- Launch policy: tasks whose kernel carries `cold_mb > 0` route to a
  profile that has completed that kernel (else the least-loaded cold
  profile, one at a time — the ramp becomes exact instead of
  probabilistic); everything else round-robins the least-loaded
  profile.
- Retires for routed kernels: the slow-start ramp, the
  `scan_compile_mb` surcharge, and the "warm-up only on pools <= 2"
  rule. All stay in place for `routed_dispatch = FALSE` (the fallback
  and the A/B).
- Validation: the existing equivalence suite (route matrix,
  mirai-equivalence, failure paths, pool affinity) run under the
  routed mode; then the SI bench on a box whose RAM allows width
  (bc-cohort box, or after B lands).

Expected effect once width is affordable: the ~850 s tail compute at
effective width 6 is ~110-150 s of drain — crop=2048 totals in the
~430-470 s range, before A1's ~100 s sweep saving.

## Sequencing

| order | item | ledger | size | gate |
|---|---|---|---|---|
| 1 | A1 smoother cache | ramet47 | done | validated by crop=512 double-run |
| 2 | B-E1..E5 characterisation | garry (+anvl audit) | ~day | none |
| 3 | B ship item(s) | garry/anvl | days, findings-dependent | B exit criterion |
| 4 | C routed dispatch | garry | ~week incl. tests | after B (or big-RAM box) |
| 5 | A2 parallel MLE | hutan | day | when cold fits matter again |
| 6 | C validation sweep | ramet47 bench | day | 3+4 landed |

Explicitly parked: CUDA for this workload (4 GB card measured 2.8x
slower end-to-end; revisit only with a per-phase device knob and a
bigger card), gd-direct fetch-cache routing (io R6 — composite-side,
bad links only), and the focal-fusion planner refinement (bilateral
pipelines, different workload).
