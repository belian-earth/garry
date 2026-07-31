# Defaults audit: `.garry_defaults` and `garry_daemons()`

Date: 2026-08-02. Scope: every option in `R/options.R` plus the
argument defaults of `garry_daemons()` (`R/scheduler.R:820`). Question
per option: is the default still right given the evidence through the
routed-dispatch validation (benchmarks/README.md, 2026-07-29 onward),
or is it a leftover from a superseded era?

## Headline verdicts

Three changes, everything else keeps:

1. **`routed_dispatch`: FALSE -> TRUE.** The C5 flip criteria are met
   on the dev box; routed strictly dominates legacy on speed and
   memory.
2. **`garry_daemons(compute = 2)`: machine-derived under routed
   dispatch** (`max(2, min(cores %/% 3, 8))`, which lands on the
   measured sweet spot of 6 on the 20-core dev box); stays 2 for
   legacy pools and for `device = "cuda"`.
3. **`garry_daemons(read = logical cores)`: cap at 8**
   (`min(cores, 8)`), pending one fast-link composite A/B as the
   validation gate.

No option needs a no-op-with-warning. The legacy-only machinery
(`scan_compile_mb`, slow start) stays live behind
`routed_dispatch = FALSE`, which remains the supported escape hatch
and A/B arm.

## 1. The `routed_dispatch` flip and its dependents

### Verdict: CHANGE to TRUE

Evidence against each criterion in `design/routed-dispatch.md` C5:

- **Both-mode suite green.** Full suite passes with the option flipped
  session-wide; the three tests with hard-coded `garry_compute`
  references were generalised to loop `.comp_profiles()`
  (routed-dispatch.md, "C5 local validation").
- **Real-workload sweep.** SI crop=2048 cost mode, c6/c8/c10 at K=2:
  399.8 / 401.2 / 412.5 s totals, tails flat at 148-149 s
  (benchmarks/README.md, "Routed width/K sweep").
- **Strict dominance.** 399.8 s vs 552.2 s for the cached anonymous
  width-2 best (2.2x on the tail phase: 148 vs 332 s), at LOWER peak
  memory (25.75 GB vs the width-2 runs), on the same box where
  anonymous width 4 OOM-killed twice at ~39 GB (README, "Routed
  dispatch validation"; routed-dispatch.md, "Validation (2026-08-02)").
- **Cost of the mechanism itself.** +12 us/task identity overhead
  (design/width1-routing-spike.md); width-16 profile creation and
  teardown in 3.6 s, so profile count is a non-issue.

The only line the design doc left open is the bc-cohort box sweep
(routed-dispatch.md, "Remaining before the default flip"). That is a
second-hardware confirmation, not a correctness gate: the suite is
green in both modes, legacy stays one `options()` call away, and the
failure mode of a wrong flip is a performance regression, not a wrong
answer. Flip now; run the bc-cohort sweep as post-flip confirmation.

### What the flip implies for the legacy-protection options

The scheduler already branches cleanly. In routed mode: `mb_eff()`
returns `t$mb` with the surcharge bypassed (scheduler.R:2037-2044),
the slow-start ramp is skipped (scheduler.R:2183-2187, `!routed`
guard), the pool-width warm-up rule is replaced by targeted scan
warm-up (scheduler.R:1466-1469), and cold-scan concurrency is bounded
structurally by `scan_profs` plus one-cold-compile-per-profile
(scheduler.R:982-1019). Nothing else needs to change at flip time.

| mechanism | disposition after the flip |
|---|---|
| `scan_compile_mb` (10000) | KEEP as a legacy-only calibration constant. It is dead code in routed mode by construction, not by warning. Do not retire: the 1500 recalibration was measured unsafe (three ~6-12 GB cold scans in one refresh window killed a 42G scope; commit c385b70; README, "Workstream B"), which proves the option still carries load whenever `routed_dispatch = FALSE`. Re-head its options.R comment "legacy pools only" so nobody tunes it expecting routed effect. |
| Cold-kernel slow start | Not an option; no user surface. Stays as legacy-path code. Retire only if the legacy pool itself is ever removed. |
| `compute_inflight` (NULL) | KEEP NULL, keep the option. In routed mode it still functions as an AGGREGATE hard cap (the launch gate at scheduler.R:2051-2052 counts pool-wide in-flight), which resolves the open question at routed-dispatch.md:124. It duplicates nothing exactly: per-profile depth 2 (scheduler.R:979) bounds per-daemon queueing, the byte budget bounds memory, and `compute_inflight` is the one knob that can force LOWER aggregate concurrency (e.g. 1 to serialise compute for debugging). Cheap, orthogonal, occasionally necessary. Document the aggregate semantics in the comment. |

A warning on setting `scan_compile_mb` under routed mode is not worth
the machinery: the option registry's tier system already labels it
calibration, and the value is honestly consumed the moment the user
drops back to legacy mode.

## 2. `garry_daemons()` argument defaults

### `compute = NULL` -> 2: CHANGE to machine-derived when routed

The 2-daemon default's stated premise (comment at
scheduler.R:826-838) is: "mirai cannot route tasks to warmed daemons,
so a wide pool multiplies compiles", plus workstream B's stronger
finding that anonymous pools rotate scans across every daemon so
width multiplies RETAINED scan memory (width 4 died twice at ~39 GB;
README, "Workstream B", "Cache + width verdicts"). Both premises are
exactly what routed dispatch removes: per-profile warmth makes
compiles exact, and scan confinement holds scan memory at K working
sets regardless of width (c10, July's OOM width, "just works routed";
README, "Routed width/K sweep").

Measured sweet spot on the 20-core dev box: compute=6, with c8/c10
adding only idle RSS and dispatch noise (399.8 / 401.2 / 412.5 s).
Recommended default when `routed_dispatch` is TRUE and
`device = "cpu"`:

```r
compute <- max(2L, min(cores %/% 3L, 8L))
```

which gives 6 on 20 logical cores. Rationale for the shape:
`cores %/% 3` tracks the "narrow daemons covering the machine"
topology (spike B: 6 daemons at k=3 = 1.35x, 10 at k=2 = 1.96x over 2
fat; README, "Thread-topology spikes"), while the cap at 8 keeps the
default inside the measured range (the width-16 probe checked only
creation/teardown, and the sweep showed nothing past 6). Keep 2 when:

- `routed_dispatch = FALSE` (the width wall is real there: README,
  "Tail-squeeze experiments", compute=4 OOM at ~38.5 GB), and
- `device = "cuda"` (compute=2 already RESOURCE_EXHAUSTED a 4 GB
  card; README, "Tail-squeeze experiments").

Fix the doc/code mismatch in the same commit: the roxygen at
scheduler.R:766-772 already PROMISES "enough narrow daemons to cover
the machine at ~2 CPUs each ... falling back to TWO", but the code
unconditionally sets `compute <- 2L` (scheduler.R:838). Today the
documentation describes the recommended future behaviour and the code
implements the past.

### `read = NULL` -> logical cores: CHANGE to `min(cores, 8)`

Two independent measurements say width beyond ~8 buys nothing and can
lose:

- Reader-width sweep (README, 2026-08-02): full 12-year runs r8
  227 s predict / 399.8 s total, r10 237 / 413.1, r20 244 / 427.3.
  r20's affinity floor (k=2 x 20 daemons = 40 masked CPUs on 20
  cores) oversubscribes the machine, spike B's measured loss shape.
  This matters at the DEFAULT settings because cost placement fuses
  kernels onto readers.
- Link-ceiling analysis (README, "What the 2.1x actually was", H3): 8
  parallel streams reach ~27 MB/s, 12 daemons aggregate ~20 MB/s;
  daemon count 12 vs 16 moved nothing. The network drain saturates
  around 8 streams.

Granularity is settled the same way: the readpx 8e6/4e6 probes LOST
(per-task overhead + halo duplication beat the admission win), so the
fix for read-side behaviour is width, not window size.

One measurement is missing: the HLS composite fetch drain
(`fetch = "auto"`, many tiny fetches) has never been run at read=8 on
a fast link; historical ceiling runs used 12-15 daemons. Gate the
change on one interleaved `compare.sh` sitting at read=8 vs
read=cores. If that sitting shows no regression, ship `min(cores, 8L)`
(floor of 4 on small machines is implicit since `min` only caps).

### `read_handles = NULL` -> `garry_opt("read_handles")` = 1: KEEP

Depth 1 suits per-slice remote mosaics (measured ~15 MB/daemon saved
at no wall cost; scheduler.R:806-813). Multi-file local plans are
told to raise it, and `read_coalesce` removed the worst per-band
revisit pattern at plan time (options.R:57-65).

### `gdal_config = TRUE`: KEEP

Applies daemon-side GDAL config without touching host discovery
(scheduler.R:842-846). No evidence against; the memory postmortem
evidence for capping the block cache per process still holds.

## 3. Option-by-option table

Verdicts justified by the evidence column; options discussed above
are cross-referenced, not repeated.

| option | default | verdict | evidence |
|---|---|---|---|
| `chunk_target_px` | 1e6 | KEEP | Per-call overhead floor (options.R:7-10). Note: README's phase-9 text says "chunk_target_px = 1.4e6 stands" but the shipped default has been 1e6 since Phase 1 (git: aecf7d1); the 1.4e6 was a benchmark-local setting. A 1e6-vs-1.4e6 sweep on the SI predict would settle it; nothing measured since contradicts 1e6. |
| `ram_budget_mb` | 512 | KEEP | Now ONLY the per-chunk size target for the chunking pass (passes.R:1004-1005); the in-flight byte cap is RAM-fraction-driven precisely because `ram_budget_mb x n_comp` both starved queued slots and overcommitted at width (scheduler.R:1041-1047). Premise intact. See coherence note on the misleading name. |
| `window_margin` | 2 | KEEP | D5 correctness containment for cross-CRS windows (options.R:13-16). Not performance-sensitive; no new evidence. |
| `progress` | FALSE | KEEP | Library-quiet default; opt-in for interactive drains. cli-based messaging policy unchanged. |
| `handle_cache_max` | 4 | KEEP | Memory postmortem: open warped mosaics pin warper + cache memory; LRU cap was one of the three fixes that brought the 3-band run to 8 GB fleet-wide (README, "Memory postmortem"). |
| `read_handles` | 1 | KEEP | See garry_daemons section. |
| `gdal_cachemax_mb` | 256 | KEEP | GDAL defaults to 5% of RAM PER PROCESS, multiplied by the fleet (README, "Memory postmortem"). Premise intact. |
| `read_target_px` | 3.2e7 | KEEP | Reader-width sweep: SMALLER windows (readpx 8e6/4e6) measured worse (per-task overhead + halo duplication; README, "Reader-width sweep"). The coarse-read rationale (options.R:39-44) is re-confirmed, not superseded. |
| `read_budget_mb` | 4096 | KEEP | Residency cap with the max-set floor (scheduler.R:1050-1056); the 145-band predict and 22-year multi-export cases it exists for are unchanged (options.R:45-56). No run has implicated it since. |
| `read_coalesce` | TRUE | KEEP | bands^2 task scaling and N-fold decompress amplification on per-band reads (options.R:57-65); byte-identical fallback retained for debugging. |
| `task_log` | NULL | KEEP | Observability must be opt-in (writes a CSV). Every recent postmortem used it, which argues for recommending it in docs, not for defaulting a file path. |
| `read_fail` | "error" | KEEP | Correctness-first; "nodata" is the operator's explicit trade (options.R:75-80), matching odc-stac/stackstac opt-in semantics. |
| `read_retry` | 2 | KEEP | Whole-operation transients (curl timeout, TLS reset) are otherwise terminal and, under "nodata", silent holes (options.R:82-91). Reads are idempotent; two retries with backoff is standard practice. No measurement contradicts. |
| `compute_inflight` | NULL | KEEP | See section 1 table. |
| `exec_ram_fraction` | 0.6 | KEEP | The admission model measured honest to ~1% at crop=2048 (modelled 13952 vs measured 14122 MB; README, "Deep-review pass validation"); confined runs peak inside their scopes at 0.6. The crop=0 42G-class need is lazy_cog staging, not this fraction. |
| `jit_warmup` | TRUE | KEEP | ~0.9 s/stage first-execution compile removed (options.R:112-115); routed mode upgraded it (targeted scan warm-up at K profiles, scheduler.R:1466-1469). |
| `device` | "cpu" | KEEP | CUDA measured a net 2.8x LOSS on the full SI workload on the 4 GB card, and compute=2 CUDA exhausts it (README, "Tail-squeeze experiments"). Explicitly parked pending a per-phase device knob and a bigger card (tail-phase-plan.md, "Explicitly parked"). |
| `fetch` | "auto" | KEEP | Remote warped read ~74% sequential network wait; tiny fetches saturate the link (options.R:122-129). No contrary measurement; the gd-direct fetch-cache routing item (io R6) is parked as bad-link-only. |
| `composite_direct` | TRUE | KEEP | Route delivers ODC parity on the reference workload (15.63 vs 15.72 s; README, "Results 2026-07-14"). The 2026-07-31 loss (47.60 vs 43.68 s) was a degraded-link sitting hitting the documented whole-slice-read variance (README, "Deep-review pass validation"), the known R6 case, not the route. |
| `gd_compute_budget` | 2.2e8 | KEEP | Calibrated at the 3-band morphology crossover (options.R:140-145); heavy composites still correctly fall through to the warm scheduler. No new crossover measurement. |
| `compute_ram_fraction` | 0.6 | KEEP | Pipeline-internal OOM guard for "use every daemon" on many-band jobs (options.R:146-153); users never set it; no incident since. |
| `ck_stage_ram_fraction` | 0.4 | KEEP | tmpfs staging pages are unreclaimable RAM; falls back to disk instead of OOM (lazy_cog.R:366-377). Composes with the compute-side cap by re-reading MemAvailable. crop=0's staging cost is inherent to the workload, not this fraction. |
| `gd_parallel` | TRUE | KEEP | Fetch-ordered pipeline is what closed the composite to ODC parity (README, "Results 2026-07-14", change 1). |
| `shm_headroom_mb` | 512 | KEEP | The backstop that clamps the store against physical /dev/shm and cgroup headroom (scheduler.R:1883-1892); the cgroup term was added from a measured thrash-at-ceiling failure. Working as designed in every confined run since. |
| `rss_correction` | TRUE | KEEP | Direct A/B: tails 414/411 s corrected vs 425 s control, i.e. the correction costs nothing measurable and the control was slowest (README, "Deep-review pass validation"). The over-tightening defect on retained scan memory was fixed with unmanaged-old semantics (scheduler.R:1846-1862) and the off-switch exists for attribution. |
| `routed_dispatch` | FALSE | **CHANGE to TRUE** | Section 1. |
| `scan_profiles` | 2 | KEEP | K=2 completes at 25.8-27.5 GB peak across c6-c10; c8 K=3 costs the ~6 GB it says and dies contained at 32G (README, "Routed width/K sweep"). K=2 is the right default for the measured hardware class; big-RAM boxes raise it per session. Revisit only after the workstream-B follow-up prices K working sets into admission so an oversized K is REFUSED, not killed. |
| `placement` | "cost" | KEEP | crop=2048 predict 551 s (rules) -> 175 s (cost, both arms fused); crop=0 completes; morphology and ndvi/composite unregressed; flipped after that sweep (README, "SI bench, second sweep"; options.R:205-214). Scheduler-route composite A/B within run variance. |
| `cost_gflops_core` | 4 | KEEP | Order-of-magnitude constant; the model's decisions separate by orders of magnitude (placement.R:138-139) and it was honest at 1% aggregate in the task report. Recalibrate from task-log traces if a wrong placement decision is ever observed, per its own comment (options.R:216-218). |
| `cost_shm_bw_mbs` | 2000 | KEEP | Same status as `cost_gflops_core`. |
| `cost_comp_efficiency` | 0.55 | KEEP | Spike B measured 0.51 (81.4 vs 159.8 win/s; README, "Thread-topology spikes"). Note it is nearly dormant at defaults: with `pool_affinity = "auto"` the capped branch (0.9 factor) applies instead (placement.R:106-113); it prices the uncapped fallback (non-Linux, no taskset). Correct on its measured premise. |
| `fuse_flops_max` | 128 | KEEP | Only bites when there is NO reader thread cap (placement.R:166-171), i.e. the same non-Linux fallback; the 145-band MLP (~2e4 flops/px) vs mask cleanup (~10) separation is unambiguous (options.R:229-235). |
| `pool_affinity` | "auto" | KEEP | Load-bearing for the whole current architecture: k=1 segfaults (hard floor 2), narrow disjoint clients ~2x fat ones, per-role masks in routed mode (spike A/B; scheduler.R:672-714, 727-755). The r20 oversubscription case is an argument for capping READ width (section 2), not for touching affinity. |
| `fuse_reader_mb` | 2500 | KEEP | Direct calibration: AEF MLP fine at ~1 Mpx (~2.4 GB/reader), three readers OOM-killed at ~4.2 Mpx (~9 GB) (README, "SI bench sweep", findings; options.R:249-255). Fusion-aware window sizing (passes.R:760-782) plans within it. |
| `scan_compile_mb` | 10000 | KEEP (legacy-only) | Section 1 table. The 10000 figure is the conservative measured value for the SI smoother's cold live set (11.8 GB observed; options.R:256-269); 1500 was tried and reverted as unsafe (d510084 -> c385b70). |
| `cost_xla_client_mb` | 350 | KEEP | Spike A measured ~277 MB per client after one trivial jit (README, "Thread-topology spikes"); 350 is a fair margin. Also reused as the per-daemon allowance in the RSS correction (scheduler.R:1906-1907), where the A/B showed no cost. |

## 4. Cross-option coherence

- **`compute_inflight` vs per-profile slot depth (routed).** Partial
  overlap, not a fight: depth 2 per profile bounds per-daemon
  queueing; `compute_inflight` is an aggregate cap that can go BELOW
  the slot total. The launch gate already composes them correctly
  (scheduler.R:2051-2052 then 2188). Action: one comment line in
  options.R stating the aggregate semantics; nothing structural.
- **`scan_compile_mb` vs `scan_profiles`.** The same risk (concurrent
  cold-scan memory) controlled by a byte proxy in legacy mode and a
  structural K bound in routed mode. Mode-scoped by construction
  (scheduler.R:2037-2044); after the flip they never both apply.
  Action: re-head both comments with their mode so the pairing is
  explicit.
- **`ram_budget_mb` vs `exec_ram_fraction`.** Resolved in behaviour
  (chunk sizing vs in-flight budget, scheduler.R:1041-1047) but the
  NAME `ram_budget_mb` still reads as the in-flight budget it no
  longer is. A rename (`chunk_ram_mb`) is a breaking change; defer to
  the next option-namespace break, keep the registry description
  ("capping chunk size") as the guard.
- **`read_target_px` vs `read_budget_mb` vs `fuse_reader_mb`.**
  Coherent triangle: the budget shrinks the window for wide input
  sets (passes.R:1042-1054), the fusion cap shrinks it for fused
  chains (passes.R:768-782), and the sweep confirmed the big-window
  bias is right. No action.
- **`pool_affinity` k-floor vs wide pools.** k floors at 2 (segfault
  floor), so any pool wider than cores/2 silently oversubscribes
  (the r20 case). With read capped at 8 and compute capped at 8 the
  defaults can no longer reach that regime on >= 4-core machines, but
  an explicit user width still can. Follow-up (small): warn at pool
  creation when `2 x width > cores`.
- **`device = "cuda"` vs the new compute default.** The
  machine-derived width must be CPU-only; CUDA keeps compute=2 (or
  the user's explicit choice). The affinity code already special-cases
  CUDA (scheduler.R:903-905); the width derivation must do the same.
- **`garry_daemons()` roxygen vs code.** The doc promises
  machine-derived compute sizing that the code does not implement
  (scheduler.R:766-772 vs :838). The flip commit resolves this in the
  doc's favour.

## Measurements that would unlock further changes

- Fast-link composite A/B at read=8 vs read=cores: gates the read
  default cap (section 2).
- bc-cohort box routed sweep (crop=2048/0, c6-10, K=2-4): post-flip
  confirmation on second hardware, and the data for whether
  `scan_profiles` should scale with RAM.
- Admission pricing of K scan working sets (workstream-B follow-up):
  turns oversized `scan_profiles` from a contained kill into a
  refusal, after which K could scale automatically.
- A `chunk_target_px` 1e6-vs-1.4e6 sweep on the SI predict: settles
  the README-vs-default discrepancy.
