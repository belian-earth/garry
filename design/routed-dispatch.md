# Routed dispatch: width-1 compute profiles with scan confinement

Date: 2026-08-02. Workstream C of `design/tail-phase-plan.md`; spike
evidence in `design/width1-routing-spike.md` (identity 200/200,
+12 us/task, mirai 2.7.1 with `dispatcher =` available). Motivation
upgraded by the workstream-B verdict: anonymous pools ROTATE scans
across every daemon, so each daemon grows to the scan's live working
set (~6-12 GB for the SI smoother) — width 4 at crop=2048 is measured
infeasible on a 62 GB box REGARDLESS of admission policy. Routing
confines scan memory to K designated daemons while map/ensemble
fleets use the full width.

## Shape

`garry.routed_dispatch = TRUE` (new option, default FALSE until
validated): `garry_daemons(read, compute = N)` creates the compute
pool as N width-1 profiles `garry_comp_1..N` instead of one width-N
`garry_compute`. Everything else — read pool, writer, store, admission
budgets — is unchanged. The host scheduler gains daemon identity; mirai
is used as-is.

Probe first: `dispatcher = FALSE` on the width-1 profiles (direct
connections, no dispatcher process per profile — the fleet would be
LIGHTER than today's dispatched pool). Fall back to dispatchered
profiles if anything (everywhere semantics, cleanup) differs.

## Seam inventory (all current-code line refs, scheduler.R unless noted)

| seam | today | routed |
|---|---|---|
| pool creation :813 | `daemons(compute, .compute="garry_compute")` | loop `daemons(1L, dispatcher=FALSE, .compute=sprintf("garry_comp_%d", i))` |
| pool query `.gd_n_compute` / `garry_daemons_set` :887,912 | one profile | sum over `.comp_profiles()` |
| affinity :716,849 | one `taskset` sweep over the pool | per-profile, explicit slice index i of N (same masks) |
| per-plan shaping `.comp_pool_shape` :716 | whole pool fat on scan plans | PER-ROLE: scan profiles fat, map profiles narrow (strictly better) |
| pids for RSS :842 | pool everywhere | loop profiles |
| hygiene loop :867 | 3 profiles | read + write + comp profiles |
| ABI check :916 region | profiles vector | append comp profiles |
| option ship / run-start hygiene everywhere | per profile | loop (mechanical) |
| warm-up broadcast :1540 | everywhere on the pool; scans only on pools <= 2 | TARGETED: map kernels on all profiles, scan kernels on the K scan profiles only (rule retired) |
| launch :2050 | `prof <- comp_prof`; pool-level `n_slot[["comp"]]`, `cap_comp` | `prof <- .route(t)`; per-profile slot counters (depth 2) |
| key-only launch :2054 | `warmed_ck[[ck]]` pool-wide (probabilistic) | per-profile warmth: key-only IFF the CHOSEN profile completed ck (exact) |
| jit-miss resend :2098 | resend to the anonymous pool | resend WITH closure to the SAME profile (`tasks[[k]]$prof`), mark it cold for ck |
| slow-start ramp :2040 | launches <= completions + 1 per kernel | RETIRED in routed mode (cold launches are exact: at most one cold profile compiles a kernel at a time) |
| `scan_compile_mb` surcharge (mb_eff :1900) | prices cold live set against the byte budget | RETIRED in routed mode: cold-scan concurrency is bounded STRUCTURALLY by K scan profiles (the surcharge's byte proxy was workload-wrong twice; K is exact) |
| composite_direct compute dispatch (composite_direct.R:555) | `prof_c = "garry_compute"` | round-robin jobs over `.comp_profiles()` |
| teardown | `daemons(0)` per profile | loop; unchanged semantics |

Central abstraction: `.comp_profiles()` returning the active compute
profile names (`"garry_compute"` in legacy mode) — every seam above
loops it, so legacy mode stays byte-identical through the same code
path.

## Routing policy

Per execution, from the plan:

- **Scan profiles:** `K = min(2, N)` profiles designated for
  scan-bearing kernels (`cold_mb > 0`), chosen stably (lowest
  indices). Scan tasks route ONLY there: least-loaded warm profile for
  the kernel, else the least-loaded designated profile that is not
  currently compiling anything (one cold compile per profile at a
  time — the exact ramp). Their live/retained memory is confined to
  K x working set by construction.
- **Everything else:** least-loaded profile over all N, preferring
  non-scan profiles when loads tie (keeps map profiles lean).
- Per-profile slot depth 2 (today's `cap_comp = 2 * n_comp`
  preserved in aggregate); the byte budgets, store gates and RSS
  correction apply unchanged on top.
- `.comp_pool_shape` by role: designated scan profiles get
  half-machine masks, the rest keep narrow disjoint masks — today's
  all-or-nothing re-mask becomes mixed, which is what spike B's
  topology data wanted all along.

## What this retires (routed mode only; legacy path keeps all three)

1. Cold-kernel slow start (probabilistic ramp -> exact routing).
2. `scan_compile_mb` surcharge (byte proxy -> structural K bound).
3. "Scan warm-up only on pools <= 2" (targeted warm-up at K profiles).

## Staged build (commit-sized, each lands green)

- **C1 — profile substrate.** `.comp_profiles()`, option, pool
  creation/teardown, affinity, pids, hygiene, ABI, broadcast loops;
  launch = least-loaded round-robin (no warmth logic). Equivalence
  suite green in BOTH modes. This alone reproduces today's semantics
  over profiles.
- **C2 — warmth + exact cold control.** Per-profile `warmed_ck`,
  key-only-iff-profile-warm, same-profile resend, ramp + surcharge
  retirement under the option, targeted warm-up.
- **C3 — scan confinement + per-role masks.** The memory payoff.
  Validation on THIS box: `compute=6` routed at crop=2048 in a 32G
  scope — map/ensemble width 6, scan memory of width 2. Expected tail
  drain ~180-200 s (scan stages hold at width-2 throughput, the
  ~8 ensemble/map stages gain ~3x).
- **C4 — composite_direct dispatch over profiles** (gd_parallel band
  fan-out).
- **C5 — validation matrix + flip.** Full suite + route matrix +
  failure paths in routed mode; SI sweep here and on the bc-cohort
  box; flip the default only after both.

## Test plan

- `test-routed-dispatch.R`: profile creation/teardown; identity
  (tasks of kernel X only on designated profiles — assert via task
  log + `Sys.getpid` markers); per-profile warmth (key-only launch to
  a warm profile succeeds, wiped profile triggers one same-profile
  resend); scan confinement (a scan plan's compute pids subset of K).
- Re-run the EXISTING gates with the option flipped in a
  setup-scoped options() block: mirai-equivalence, route-matrix,
  scheduler-failures, writer-errors, pool-affinity, jit-key-only,
  slow-start expectations (ramp asserted only in legacy mode).
- Failure modes: kill a designated scan profile mid-drain (classed
  abort, pools rebuildable); kill a map profile (same).

## Risks / open questions

- `dispatcher = FALSE` semantics for `everywhere()` and queued tasks
  on width-1 profiles — probe in C1; fall back to dispatchered.
- N profile sockets at large N (bc-cohort widths): spike showed 8 is
  free; check 16.
- The task log's pool column should carry the profile name (free
  daemon attribution — the observability item the review wanted).
- `compute_inflight` option semantics in routed mode (map to
  aggregate slots).
- hutan/ramet47 touch nothing: `garry_daemons()` signature unchanged.

Estimated size: C1 ~250 lines net (mostly mechanical loops), C2
~150, C3 ~120, C4 ~80, plus ~400 of tests. One focused session per
stage.

## Validation (2026-08-02)

C1-C3 landed (commits 60cc1ae, 0c2ccff; full suite green in both
modes). SI crop=2048 cost, compute=6 routed, MEMMAX=32G, this box:
total **399.8 s** (tail phase 148 s, peak scope anon 25.75 GB) vs the
cached anonymous width-2 best 552.2 s (tail 332 s) and two anonymous
width-4 OOM deaths at ~39 GB. Confinement verified from the task log
(scan launches only on garry_comp_1/2) and /proc masks (fat scan
profiles, narrow map profiles). C3's expected-effect estimate
(~180-200 s tail) was beaten. Remaining: C4 is already covered by the
C1 round-robin; C5 (bc-cohort validation + default flip) stays open.

## C5 local validation (2026-08-02)

The FULL suite runs green in both modes (legacy defaults and
`routed_dispatch = TRUE` flipped session-wide, every pool the suite
creates routed). The flipped sweep surfaced exactly three tests with
hard-coded `garry_compute` references (mirai-pools cache count,
pool-affinity mask collection, scheduler-failures daemon-kill mock) —
all now loop `.comp_profiles()` and pass in both modes. Added
`garry.scan_profiles` (default 2) as the K knob for big-RAM sweeps.
Width-16 probe: 16 routed profiles create, run a distributed collect,
and tear down in 3.6 s — profile-count scaling is a non-issue at
bc-cohort widths.

Remaining before the default flip: the bc-cohort box sweep
(crop=2048/0, compute=6-10, scan_profiles=2-4) — different hardware,
user-driven.
