# Deep review 2026-07-31: testing posture and operational maturity

Branch: `placement-pass` (HEAD 3033623). Scope: `tests/testthat/` (83 test
files, 376 `test_that` blocks, ~8.0k lines against ~11.7k lines of R), the
option registry (`R/options.R`, 32 options), the CI workflow, and the
operational surfaces a production consumer (hutan/ramet47) depends on.

## Verdict

The suite is unusually strong on semantics: a pure-R oracle
(`helper-oracle.R`), property-based geometry tests, external oracles (terra,
KFAS, `apply()`, finite differences), architecture guards
(`test-backend-insulation`, `test-gdal-quarantine`), and a consistent
"distributed == single-threaded" gate across ~15 files. It is weak in three
places, in rising order of production risk: (1) the newest scheduler
resource-management mechanisms (slow start, compile surcharge, flush timing,
pool re-masking) have no direct tests; (2) `composite_direct.R`, the DEFAULT
distributed route for composites and 856 lines of divergent executor, has no
offline equivalence gate at all; (3) failure modes (daemon death, write
failure, version skew, teardown) are untested and mostly surface as unclassed
aborts, which matters now that another team's pipeline catches garry errors.

**The suite is not green at HEAD.** A full run for this review (339 s wall)
found 4 failures, all introduced by the branch's two newest commits and
undetected because the suite was evidently not re-run after them:

- `test-gdal-quarantine`: the writer daemon (`.daemon_write_chunk`,
  scheduler.R:186, commit 31357c4) constructs `gdalraster::GDALRaster`
  directly, violating the adapter quarantine the guard exists to enforce.
  Either route the open through `gdal_adapter.R` or extend the allowlist
  deliberately.
- `test-store-residency` (3 assertions): commit e452807 (f64 store) changed
  `.store_region_mb`'s last argument from the `use_raw` logical to element
  `bytes`; the unit test still passes `TRUE`/`FALSE`, which now coerce to
  1/0 bytes. The test is stale, not the code, but a stale-green assumption
  is exactly what section 6's additions are meant to prevent.

This validates the review's central thesis directly: mechanism commits are
landing faster than their tests, and the newest 15 commits (writer daemon,
f64 store, slow start, surcharge, pool shaping) are the least-tested code in
the package.

## 1. Coverage map

| Subsystem | Files (lines) | Tests | Standing |
|---|---|---|---|
| Grid / geometry | grid.R (329), chunk_grid.R (207), grid_from.R (140) | test-grid, -grid-convention, -grid-crs, -grid-from, -chunk-grid, -cross-grid-window | Strong. Property tests (200-draw chunk tiling), brute-force window oracle, a captured regression (corner-only under-coverage). |
| IR / graph / dtype | node.R, graph.R, generics.R, dot.R | test-graph, -graph-merge, -ir-output-grid, -dtype, -nodata-dtype-ir | Strong. Promotion table locked as a spot table. |
| Kernel vocabulary | ops.R (701) | test-ops-oracle (pure R), -ops-anvl-parity (traced == untraced), -backend-insulation | Strong. The oracle-then-parity pattern is the package's best idea. |
| Planner passes | passes.R (1073) | test-planner-golden, -stage-merge, -plan-halo, -halo-propagation, -planner-scale, -focal-placement, -launch-order, -read-budget, -band-coalesce, -kernel-cache | Strong; goldens plus behavioural gates for each pass. |
| Executor | executor.R (672), plan.R | helper-oracle; test-plan-oracle-exec, -executor-e2e, -chunk-invariance, -align-pipeline, -write-roundtrip, -multiband-write, -multi-export, -nodata-e2e | Strong. Chunked == whole proven independently of anvl. |
| GDAL adapter | gdal_adapter.R (709) | test-gdal-grid, -gdal-read-window, -gdal-read-orientation, -handle-cache, -gti, -warp, -gdal-quarantine | Strong; terra as external oracle; orientation fixtures asymmetric by design. |
| Scheduler | scheduler.R (2020) | test-mirai-equivalence, -mirai-pools, -raw-store, -compute-on-read, -mem-admission, -store-residency, -jit-key-only, -fetch-assemble, -pool-affinity, -allocator-stress, plus distributed arms in ~12 other files | Broad on END-TO-END equivalence, thin on the internal mechanisms added since 2026-07-29 (see below). |
| Placement | placement.R (259) | test-placement, -placement-cost, -fuse-wide | Good: pass-level decisions plus an end-to-end fused == oracle gate, both modes round-tripped on multi-export. |
| Composite fast paths | composite_direct.R (856) | test-gd-general only | **`.gd_spec`/`.execute_gd_general`/`.gd_decompose`/`.execute_gd_reduce` are gated byte-identically against the scheduler on a local GTI fixture. `.cd_spec`/`.execute_composite_direct`/`.execute_composite_pipeline` (the default route when daemons are up) have NO offline test; see section 2.** |
| API layer | lazy_raster.R, dataset.R, stac.R, lazy_cog.R | test-lazy-map, -map-broadcast, -stack, -dataset (18), -group-by-time, -stac-* (5 files), -lazy-cog (16) | Strong, including offline STAC fakes and a local-COG cptkirk path. |
| Numerics | gradient.R, scan_kalman.R, band_mlp.R | test-grad-* (5 files, FD gates, NaN-poison semantics), -scan-custom, -scan-kalman-kfas, -reduce-mlp, -reduce-custom, -reduce-band, -focal-bilateral | Excellent; KFAS and finite differences as oracles. |
| Presentation | preview.R, draw.R | test-preview, -draw, -plan-dot (snapshot) | Adequate. |
| Options | options.R (244) | only `exec_ram_fraction` has a registration test | Thin; see section 4. |
| zzz.R | GDAL version warning | none | Trivial, acceptable. |

### Load-bearing mechanisms with no direct test

All confirmed by grep; file:line on this branch.

1. **`flush_drops` timing** (scheduler.R:1301): the 5 s clock and the
   quarter-of-read-budget byte trigger are unasserted, and no test verifies
   regions PHYSICALLY unlink (test-allocator-stress watches the R heap, not
   /dev/shm). A regression here is silent tmpfs growth, the exact crop=0
   failure class.
2. **`refresh_mem_budgets` arithmetic** (scheduler.R:1514): the pool/3 read
   split, the `store_mb_max`/`task_mb_max` floors, and the min(host, cgroup)
   composition are covered only by "completes under a squeeze" liveness tests
   (test-mem-admission, test-store-residency). The mocking pattern those tests
   already use (`local_mocked_bindings` on `.garry_shm_free_mb`) extends
   directly to asserting the computed budgets.
3. **Cold-kernel slow start** (`ck_inflight` ramp, scheduler.R:~1706; commit
   6f6e121): nothing asserts the 1, 2, 3... launch ramp.
4. **`scan_compile_mb` surcharge** (`mb_eff`, scheduler.R:1226/1655; commit
   7b2467c): the cold-compile byte surcharge and its expiry ("as many
   completions as daemons") are untested, as is the "warm-up only on pools
   <= 2" policy.
5. **`.comp_pool_shape` re-masking** (scheduler.R:566): scan plans re-mask the
   compute pool to half-machine slices, fleet plans restore narrow masks.
   test-pool-affinity covers creation-time affinity only.
6. **Writer-daemon error paths**: happy path is covered (streamed-write
   equivalence in test-mirai-pools, test-multi-export since commit 31357c4);
   a failed `.daemon_write_chunk`, the `harvest_writes` abort
   (scheduler.R:~1694), and the post-abort close (`on.exit`, scheduler.R:1422)
   are not. The host-inline fallback branch (`writer_on = FALSE`) is now
   near-dead code with no dedicated test and will rot.
7. **Host-side jit-miss resend** (scheduler.R:1817-1825): test-jit-key-only
   covers the daemon-side signal only. The resend-once path, and its
   interaction with a resent task that feeds a streamed sink, are untested.
8. **Remote fetch/assemble**: the local `fetch = "force"` proxy is well tested
   (test-fetch-assemble, including the nodata-hole degradation and overview
   decimation); the genuinely remote /vsicurl path runs only in benchmarks.
   Acceptable, but it means `read_fail` behaviour against real 403/timeout
   errors is unverified.
9. **Daemon death mid-drain**: an errorValue from a dead daemon falls into the
   generic unclassed abort at scheduler.R:1826. Untested.
10. **Teardown segfault** (live XLA client at `daemons(0)`; benchmarks/README
    spike A): known, called benign, never asserted. No test checks that
    teardown leaves no orphan /dev/shm regions and a usable host.
11. **Version skew host vs daemons**: no guard exists (section 4).
12. Untouched options: `progress`, `compute_inflight`, `read_handles`,
    `read_target_px`, `window_margin`, `gd_compute_budget` (routing
    threshold!), `gd_parallel`, `gdal_cachemax_mb`, `ram_budget_mb`, the four
    `cost_*` calibration constants, `scan_compile_mb`, `jit_warmup = FALSE`.

## 2. Equivalence discipline

The oracle model is sound and consistently applied: `execute_plan` is the
semantic reference; `helper-oracle.R` proves chunked == whole below it;
distributed paths gate against it at 1e-6..1e-12 or byte-identical
(`.gg_identical` in test-gd-general: identical NaN pattern plus tolerance 0);
traced kernels gate against untraced R.

Routes with a gate today: scheduler (rules and cost, incl. fused sinks, raw
f32/f64 store bit-exact, coalesced plans, halo compute-fed focals, scans,
custom reducers, multi-export streamed writes); `.execute_gd_general` and
`.execute_gd_reduce` byte-identical to the scheduler on offline GTI fixtures.

Gaps, in priority order:

1. **`.execute_composite_direct` / `.execute_composite_pipeline` have zero
   offline gate.** test-gd-general asserts `.cd_spec(p)` is NULL for its
   shapes, deliberately. Nothing anywhere runs the `.cd_spec` route offline,
   although the `.gg_gti` fixture (local GTI + `.meta.rds` sidecar) is exactly
   what it needs. The production default composite path, including warp-into-
   buffer, the fetch-ordered pipeline, `gd_parallel` fan-out,
   `compute_ram_fraction` admission and the `gdirect-<pid>` cube cache (whose
   PID-keyed collision the scheduling review already flagged), is validated
   only by the network benchmark's output diff. A refactor that breaks it in a
   way `compare.sh` is not run against ships silently.
2. **Route selection is untestable from outside.** `collect()` picks
   cd_spec -> gd_decompose -> scheduler silently (collect.R:83-94), and the
   thresholds (`gd_compute_budget`, `.gd_pooled()`, `gd_parallel`) have no
   test. A plan silently changing route is precisely the regression class an
   equivalence suite must catch, and today it cannot even be observed. A
   one-line route annotation (option-gated message, or an attribute on the
   result) would make both this and item 1 assertable.
3. **No systematic cross-product.** The matrix {oracle, scheduler-rules,
   scheduler-cost, gd_reduce, composite_direct} x {in-memory, written} x
   {writer on, host-inline} exists only as scattered pairwise checks. One
   canonical masked composite plus one scan plan swept through every offline
   cell would close it at modest runtime cost.
4. Placement rules-vs-cost is round-tripped on multi-export and raw-store
   shapes but not on scan-bearing or focal plans (scans-never-fuse is asserted
   at pass level only).

## 3. Failure-mode testing

What exists: `read_fail = "nodata"` degradation (dead source, failed fetch)
is genuinely tested; OOM-ADJACENT LIVENESS is the best-covered failure class
(starved store budget, mocked near-full /dev/shm, `exec_ram_fraction = 1e-6`,
all asserting serialise-not-deadlock plus correct results). Structured errors
for planner refusals are tested by class throughout.

What does not exist, all feasible cheaply:

- **Kernel failure mid-drain**: a stage fn that `stop()`s aborts via a bare
  `cli_abort("task {k} failed on daemon")` (scheduler.R:1826). No class, no
  task/stage context fields, and no test that the abort path runs its
  cleanup (`.daemon_shm_clear` everywhere, fetch root unlink, sink close are
  all `on.exit`'d at scheduler.R:793/815/1422/1433 but never verified).
- **Daemon death**: killing a read daemon mid-drain (`tools::pskill`) is a
  five-line test; today it surfaces as the same unclassed abort. No retry
  exists by design (scheduling review: "no retry machinery"); fine, but the
  failure should be classed and the store verifiably clean afterwards.
- **Write failure**: mock `.daemon_write_chunk` to error, or chmod the target;
  assert the classed abort, that the `wr_inflight` wait loop cannot hang, and
  that the writer's open handle is closed (file removable afterwards).
- **Teardown**: no smoke test that `garry_daemons(0, 0)` after jitted work
  leaves the host alive and /dev/shm free of `r<run>_*` regions. The known
  XLA teardown segfault stays folklore until a test bounds its blast radius.
- **Interrupt**: host Ctrl-C mid-drain relies on the same `on.exit` chain;
  hard to test portably, acceptable to leave, but worth a manual checklist
  entry in the design docs.

## 4. Operational surfaces

**Options (32).** Documented only as source comments in `options.R`;
`garry_opt.Rd` does not enumerate them and no vignette does. For a package
consumed by another pipeline this is the largest ops gap: there is no way to
discover a knob without reading source. Three tiers are mixed in one flat
namespace: user-facing (progress, task_log, device, read_fail, fetch,
placement, read/compute pool knobs), tuning (budgets, fractions, targets),
and calibration constants (`cost_gflops_core`, `cost_shm_bw_mbs`,
`cost_comp_efficiency`, `cost_xla_client_mb`, `scan_compile_mb` = one
workload's 10 GB measurement). Recommend a generated `garry_options()`
surface (name, default, current, tier, one-liner) and a man page.

**Validation.** `garry_opt` validates names, never values. `fetch` and
`placement` are checked at use (good; `garry_placement_error` is classed and
tested). `read_fail` is compared with `identical(x, "nodata")` at four sites:
any typo silently means "error", inverting the operator's stated intent on a
22-hour run. Three sibling RAM fractions (`exec_ram_fraction`,
`compute_ram_fraction`, `ck_stage_ram_fraction`) accept any numeric silently.
A cheap `.garry_opt_check()` at `execute_plan_mirai`/`collect` entry closes
this.

**Error classes.** `.garry_error` (passes.R:23) is good discipline and
planner-side classes are tested. Runtime scheduler failures (task failed,
sink write failed, fetch failed under "error" mode, deadlock is classed but
the other three are not) use bare `cli_abort`: a consumer cannot distinguish
"daemon died" from "my mask function is wrong" programmatically. Add
`garry_task_error`/`garry_write_error` carrying task key, stage id and pool.

**Observability.** `garry.task_log` CSV (epoch,event,key; events launch /
done / write / drain_end / host_end) has no documented schema and no reader;
every diagnosis in the design history was ad-hoc parsing. A
`garry_task_report(path)` (per-stage counts and durations, max concurrency,
drain vs host tail) converts it from developer trace to operator tool and
locks the schema. `garry_explain_placement()` is the model. Minor: the
progress line uses `cat` (scheduler.R:~1902), not cli, against the project's
own convention.

**Install coupling and version skew.** Daemons `library(garry)` from the
installed library (scheduler.R:776, garry_daemons setup); the host is
frequently a `devtools::load_all` tree. Entry points resolve as
`garry::.daemon_*` on the DAEMON side, so a host/daemon namespace skew yields
"unused argument" mirai errors at best and silent semantic drift at worst
(e.g. the `out_keys` positional renaming, the `edge` masking argument:
recent additions exactly of this shape). There is NO guard, and none is
possible via `packageVersion` (constant 0.0.0.9000 through development).
Recommend an ABI token: `rlang::hash` over the formals of every `.daemon_*`
function plus the store layout version, compared host-vs-daemon once per
pool at `execute_plan_mirai` entry, aborting with a classed
`garry_version_skew_error` ("run devtools::install() and restart daemons").
This also fixes the local-dev variant: 31 tests skip via
`skip_if(!requireNamespace("garry"))` and then exercise the INSTALLED
namespace on daemons while the host runs source, so a stale install can turn
parts of a green local run into a test of last week's scheduler.

## 5. CI and checkability

- `.github/workflows/R-CMD-check.yaml`: 5 configs (macOS, Windows, Ubuntu
  devel/release/oldrel), recent GDAL from ubuntugis/brew, gdalraster rebuilt
  from source, r-universe extra repo with `PJRT_INSTALL=1`, so anvl/mirai
  Suggests install and the distributed suite runs in CI. Snapshots uploaded.
  This is a genuinely strong setup for a package this stack-heavy.
- Gating is coherent: network opt-in (`GARRY_RUN_NETWORK`), scaling opt-in
  (`GARRY_RUN_SCALING`), stress opt-out (`GARRY_SKIP_STRESS`), CUDA and KFAS
  auto-skip. The composite/NDVI parity numbers are correctly bench-gated
  (network-sensitive, same-sitting interleave per benchmarks/README) and NOT
  in the suite; the missing piece is the OFFLINE composite_direct gate
  (section 2), not benchmarks-in-CI.
- Full local suite (this review, 16 GB systemd scope, 20-core box with
  CUDA): 339 s wall, 4 failures (see Verdict), 2 env-gated skips (network,
  scaling), 1 warning. ~5.7 minutes is acceptable for pre-commit but the
  long poles (grad-convergence, kalman-KFAS, the distributed equivalence
  files) suggest a fast tier convention before the additions below grow it.
  The one warning is itself a message-quality bug: under a tiny budget the
  oversized-chunk warning prints "estimated at 0 GiB, above the 0 GiB
  execution budget" (rounding erases both numbers; print MB below 1 GiB).
- Hygiene: `tests/testthat/Rplots.pdf` is regenerated by preview tests (wrap
  plotting in `withr::local_pdf`/`pdf(NULL)`); stale `_problems/` extracts
  from July 8 and `benchmarks/*.aux.xml` are untracked clutter; `design/`,
  `benchmarks/` correctly `.Rbuildignore`d.

## 6. Ten highest-value additions (prioritised)

Item 0, before any addition: fix the 4 existing failures (quarantine
violation at scheduler.R:186; `.store_region_mb` unit test updated to the
`bytes` signature with 4/8, plus a companion f64 case asserting the old
half-size booking stays fixed) and re-establish "suite green" as the merge
bar for scheduler commits.

1. **test-composite-direct.R: "composite_direct matches the oracle on a local
   GTI composite".** Reuse `.gg_gti`; assert `.cd_spec(p)` is non-NULL, run
   `collect(distributed = TRUE)` vs `execute_plan`, compare with the strict
   NaN + tolerance-0 comparator. Variants: multi-band with shared mask
   (`gd_parallel` TRUE and FALSE), morphology (halo) band, and
   `gd_compute_budget = 1` forcing the scheduler fall-through (assert route
   changed AND results identical). Closes the only untested executor.
2. **test-route-matrix.R: one masked composite and one scan plan through
   every offline route.** {oracle, scheduler-rules, scheduler-cost,
   gd_reduce, composite_direct} x {in-memory, path-written}; assert all equal
   and assert which route ran (add a `garry.route_trace` option or result
   attribute as the enabling one-liner). Catches silent route flips forever.
3. **test-scheduler-failures.R: "a failing kernel aborts classed and leaves a
   clean store".** Map fn that errors on one chunk; expect new
   `garry_task_error` (with task key and stage id); then scan /dev/shm for
   `r<run>_*` leftovers (none) and re-run the plan successfully on the same
   pools. Second block: `tools::pskill` one read daemon mid-drain; expect
   classed abort, clean store, pools rebuildable.
4. **test-writer-errors.R: "a failed sink write aborts, does not hang, and
   closes the output".** Mock `.daemon_write_chunk` to error (pattern:
   `local_mocked_bindings`); assert classed `garry_write_error`, the
   post-drain `wr_inflight` loop exits, and the target file is closed and
   deletable. Third assertion: the `writer_on = FALSE` host-inline fallback
   still matches the oracle (keeps the fallback alive).
5. **ABI skew guard + test-version-skew.R.** Implement the `.daemon_*`
   formals-hash token checked at `execute_plan_mirai` entry; test by mocking
   the daemon-side token to differ, expect `garry_version_skew_error` naming
   both hashes; positive case passes. Prerequisite feature, small.
6. **test-slow-start.R: cold-kernel ramp and scan surcharge are visible in
   the task log.** `jit_warmup = FALSE`, one kernel, 8+ chunks, task_log on:
   assert launches of that kernel never exceed completions + 1 (parse the
   log; no timing sensitivity). Second block: mock `scan_compile_mb` above
   the budget and assert cold scan tasks serialise (at most one in flight
   until first completion) while warm tasks flow.
7. **test-comp-pool-shape.R: scan plans fatten the compute masks and fleet
   plans restore them.** Linux + taskset only (skip otherwise, as
   test-pool-affinity does): read `Cpus_allowed_list` from
   `/proc/<pid>/status` after executing a scan-bearing plan, then after a
   map-only plan; assert half-machine vs narrow-disjoint patterns.
8. **test-jit-miss-resend.R: the host resends once and the result is
   unchanged.** After warm-up, wipe `.daemon_cache` on the compute pool via
   `mirai::everywhere`, drain, assert completion and equality with the
   oracle; variant where the resent task feeds a streamed sink (exercises
   the resend + write interaction).
9. **test-shm-hygiene.R: no orphaned /dev/shm entries after any route or
   teardown.** Snapshot `/dev/shm` before; run each offline route, an
   aborted run, and `garry_daemons(0, 0)`; assert the entry set is restored
   and the host session still executes a plan. Bounds the known teardown
   segfault and the flush_drops leak class in one cheap sweep.
10. **`garry_task_report()` + test-task-report.R.** Summarise a task_log:
    totals per event, per-stage task counts and p50/p95 durations, max
    concurrency, drain vs host-tail split; test against a log captured from
    a small distributed run (assert totals equal the plan's task count and
    events are complete pairs). Locks the CSV schema and gives hutan an
    operational tool instead of raw CSV.

Below the cut but recommended: option-value validation at execute entry with
a test that every default validates and that a `read_fail` typo errors
rather than silently meaning "error"; a `garry_options()` registry surface
and man page; cli-ify the progress line; delete `Rplots.pdf`/`_problems`
artifacts and add them to local ignores; fix the stale `garry.read_affinity`
reference in design/placement-cost-pass.md:13.
