# Deep review 2026-07-31: synthesis

Five reports in this directory: `execution-vs-dask.md`,
`datamodel-vs-xarray.md`, `io-vs-odc-stackstac.md`, `defect-hunt.md`,
`testing-ops.md`. Scope: the whole package, with the 25
`placement-pass` commits (commits-in-scope.txt) under adversarial
focus, cross-compared against dask.distributed, xarray, and the
odc-stac/stackstac/rioxarray stack from their documentation and
source, not from memory.

## Verdict

The architecture holds up against the reference systems better than
expected, and the review's sharpest findings are not architectural:
they are one silent-wrong-output defect (fixed during the review), a
testing-lag pattern, and a short list of adoption-worthy ideas from
systems that solved adjacent problems. The central asymmetry the
comparison surfaced: **dask measures and reacts; garry models and
admits.** For introspectable raster workloads garry's side of that
trade is stronger (the placement pass has no dask analog; fusion
compiles below the task boundary where dask fuses Python callables) —
but every recent garry defect was an estimate diverging from reality,
which is precisely the seam dask's measurement machinery covers. The
roadmap below therefore adds measurement where garry is blind, not
reaction where garry's model is sound.

## Two-way ledger

Where garry is genuinely AHEAD of the references:
- Kernel fusion to single compiled XLA programs, including fusion onto
  read workers via the cost placement pass (no analog in dask).
- Intra-machine thread topology as a scheduled, per-plan resource
  (pool affinity, shaping); dask has static nthreads and no affinity
  concept.
- Byte-based admission against live RAM/cgroup/shm vs dask's
  count-based heuristics; spill tiers dissolved by admission-first.
- Warp-on-read grid semantics (explicit analysis grid), lazy
  mask/morphology vocabulary, preview(), the scan node (KFAS 4.8-7.8x),
  solar-day compositing correctness vs UTC resample.
- Fetch/assemble request shaping on fast links (measured 50.3 vs
  ~20 MB/s); MPC collection-token caching.

Where garry is BEHIND, adoption-worthy:
- No task-scoped retry for cloud reads (single attempt, then hole or
  abort). dask/odc/stackstac all retry; reads are idempotent.
- No per-daemon memory measurement (aggregate clamps only, 5 s
  cadence); dask polls worker RSS at 200 ms. Every OOM in the sweep
  history would have been a throughput dip under a measured
  correction term.
- Temporal identity: `t` is a bare size; slice dates are stripped at
  the stack boundary. No label selection, spacing-blind scans,
  unlabelled outputs. Bounded fix (GridSpec labels), not a coord-array
  model.
- Observability: task_log CSV lacks pid/bytes/queue-wait; the
  topology work needed external per-PID tracers. No report function.
- Ops-surface hygiene: 32 options with no registry doc or validation;
  unclassed mid-drain errors; no host/daemon version-skew guard.
- Daemon-identity routing (mirai cannot target a warmed daemon) is
  the root of the cold-compile machinery; a width-1-profile spike
  could dissolve slow start + surcharge into ordinary placement.

Explicitly REJECTED after comparison (recorded so they stay
rejected): work stealing, spill-to-disk tiers, nanny processes,
abstract resources, adaptive scaling, live dashboards, x/y coordinate
arrays, xarray-style auto-alignment, data-value groupby, HLG-style
lazy graph materialization (wrong scale by ~10x).

## Defects (hunt over the 25 new commits)

1 high / 2 medium / 5 low; the writer refcount discipline, resend
byte accounting, f64 write demotion and the bench-path suspects all
verified clean by live probes. Fixed during the review: **H1**
(source-as-sink silently lost its raw band — fused variant
default-reachable, split variant pre-existing; both closed +
regression test), **M2** (failed warm-up bypassed the cold-compile
budget on resend), **M1** (silent >2 GiB `.sv_trim` overflow, now a
loud abort). Also fixed: the 4 test failures at HEAD the testing
review caught (adapter-quarantine violation by the writer daemon;
3 stale store-sizing assertions). Lows L1-L5 remain catalogued in
`defect-hunt.md` (throttling-only or noisy-failure-after-failure
class).

## Re-prioritized roadmap

Tier 1 — correctness/robustness debt, small and evidence-backed:
1. Task-scoped read retry with exponential backoff + jitter
   (io R1/dask #1; ~25 lines at the three read/fetch seams).
2. Testing item 0 follow-through: composite-direct offline gate and
   the route-matrix cross-product (the DEFAULT distributed composite
   route has zero offline test; route flips are silent).
3. Host/daemon ABI skew guard (formals hash of `.daemon_*`, classed
   error) — the install-coupling failure mode is currently undefined
   behavior.
4. Writer-daemon failure-path tests + L3 on.exit ordering.

Tier 2 — measurement where the model is blind:
5. Per-daemon RSS poll folded into refresh_mem_budgets as a
   correction term (pids already collected for affinity).
6. task_log widening (pid, store_mb, ready-time) +
   `garry_task_report()`; would have shown the crop=0 flood as
   diverging modelled-vs-measured lines.
7. Option registry doc + value validation; classed task/write errors.

Tier 3 — the data-model gap:
8. GridSpec labels for t/band (xarray #1: bounded, planning-neutral)
   -> time_sel(), labelled outputs, dt-aware scans, slice inner-join.
9. Ops/Math generics registration; grid_diff() in alignment errors;
   as_terra(); scan-based ffill/interpolate helpers.

Tier 4 — spikes with option value:
10. Width-1 mirai profiles for daemon-identity routing (could retire
    slow start/surcharge and unlock warmed-daemon reuse).
11. Expiry-aware re-signing for long runs (io R4); retry-code list
    and ALLOWED_EXTENSIONS widening (io R2/R3, tiny).

The hutan-gap items (tail scan on GPU, hutan-side point fits) stay on
the hutan side of the ledger and are deliberately NOT in this
roadmap: the engine's next unit of work should pay generality, per
the review's charter.
