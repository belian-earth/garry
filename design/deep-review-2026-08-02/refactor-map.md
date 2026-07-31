# Refactor map: post-accretion consolidation (2026-08-02)

Scope: structure and duplication only, after two weeks of feature work on
`placement-pass` (routed dispatch, raw-BSQ cube IO, daemon hygiene, RSS
correction, read retry, GridSpec labels, option registry). Not a bug hunt.
Every proposal below is gated on the equivalence suite staying green; none
changes observable behavior except where a blind spot is called out (R2).

## Ranked actions

| # | Action | Payoff | Risk | Section |
|---|--------|--------|------|---------|
| 1 | Split scheduler.R into daemon.R / pools.R / scheduler.R | high | very low | R1 |
| 2 | Move composite_direct daemon bodies into daemon.R as `.daemon_*`; closes the ABI-token blind spot | high | low | R2 |
| 3 | Test helper `with_pools(read, comp, ..., code)`: covers ~55 of 72 pool spin/teardown sites | high | low | R12 |
| 4 | `.pool_broadcast()` + `.daemon_setup()`: one idiom for the 9 profile-loop everywhere() sites | medium | low | R3 |
| 5 | Shared host sink tail `.exec_sink_tail()` + consumer index for both executors | medium | low | R4 |
| 6 | Test fixture consolidation: recipe families A+B (17 inline sites) into parameterised helpers | medium | low | R12 |
| 7 | Extract the task-build loop from execute_plan_mirai; ledger and router objects as follow-ups | high | medium | R5 |
| 8 | One raw-payload wrap + one nodata-to-NaN helper across the three read paths | medium | low | R7 |
| 9 | options.R: merge defaults and registry into one table | medium | very low | R8 |
| 10 | Dead-code and stale-comment sweep (`pooled` flag, pre-routed and pre-mori comments, phase-N roxygen) | medium | very low | R9, R11 |

Below the line: composite_direct dispatch unification beyond the shared
seams (R6) and a wholesale error-idiom rewrite (R10); both are churn
that exceeds payoff, with the cheap subset of each folded into the items
above.

Deliberately not proposed: extracting `refresh_mem_budgets` and the
admission gates (`read_ok`/`store_ok_comp`/`mb_eff`/`comp_ok`,
scheduler.R:1863-2055) into their own object. They are the most entangled
closures (they read `mb_inflight`, `mb_store_resident`, `warmed_ck`,
`ck_done`, `n_inflight` live), the test suite gates equivalence rather
than memory behavior, and every recent defect hunt happened in exactly
this code. Extract them only as a follow-up once R5 has given the drain a
shared state environment they can close over unchanged.

## R1. scheduler.R is three files (2,496 lines, one function is 1,540 of them)

`execute_plan_mirai` spans scheduler.R:956-2496. The file has three
distinct populations with no shared closures between them:

- **daemon.R** (new): everything that executes on daemons plus the ABI
  machinery. scheduler.R:22-455: `.daemon_cache`, `.garry_malloc_trim`,
  `.daemon_hygiene`, `.garry_state`, `.garry_store_abi`,
  `.garry_abi_token`, `.garry_abi_check`, `.daemon_shm` registry,
  `.daemon_shm_clear/drop`, `.apply_fuse`, `.daemon_run_source_shm`,
  `.daemon_write_chunk`, `.daemon_write_close`, `.daemon_fetch_window`,
  `.daemon_run_compute_shm`, `.daemon_warm_jit`.
- **pools.R** (new): machine probes and pool lifecycle.
  scheduler.R:502-944: `.garry_cores`, `.garry_cgroup_avail_mb`,
  `.garry_ram_avail_mb`, `.garry_shm_free_mb`, `.garry_fmt_mb`,
  `.comp_profiles`, `.comp_n`, `.garry_pool_pids`, `.garry_anon_mb_of`,
  `.garry_fleet_anon_mb`, `.store_region_mb`, `.store_bytes_of`,
  `.node_outer_nb`, `.garry_env_defaults`, `.pool_affinity_apply`,
  `.comp_pool_shape`, `garry_daemons`, `garry_pool_hygiene`,
  `garry_daemons_set`. Pull `.gd_n_compute` (composite_direct.R:314-317)
  in here too; it is a pool probe the scheduler already depends on, and
  `.gd_pooled` (composite_direct.R:321) is a pure alias of
  `garry_daemons_set` that can be deleted.
- **scheduler.R** keeps `.stage_kernel_sig` (457-499) and
  `execute_plan_mirai`.

Pure file moves, no signature changes; only `@include` collate order
needs care. This is the highest payoff-per-risk item and it is a
precondition for R5 reading well.

## R2. Daemon task bodies in one file, and the ABI-token blind spot

`.garry_abi_token` (scheduler.R:82-91) hashes the formals of every
namespace function matching `^\.daemon_`. It is a namespace scan, not a
file scan, so consolidation per se cannot break it. But composite_direct
grew five daemon entry points that are invoked cross-process via
`garry::` and are **not** enrolled:

- `.cd_fetch_warp` (composite_direct.R:289, launched at 403 and 577)
- `.gd_warm` (68, broadcast at 590)
- `.gd_compute_mask` (106, launched at 607)
- `.gd_compute_masked_band` (126, launched at 643)
- `.gd_compute_band` (81)

All five are exported (NAMESPACE:5,18-21) exactly like the `.daemon_*`
set, and `.gd_daemon_prep` (composite_direct.R:385-392) even calls
`.garry_abi_check` first, but the token never covers their formals: a
host/daemon skew in the composite-direct pipeline passes the ABI gate
today. Sketch: move them into daemon.R and rename with the `.daemon_`
prefix (`.daemon_fetch_warp`, `.daemon_gd_warm`, ...), keeping thin
deprecated aliases for one cycle if the hutan pairing addresses them by
old name. The rename enrolls them in the token with zero token changes.
This is the one refactor here that fixes a real gap rather than
aesthetics; rank it with R1.

## R3. Profile-loop broadcast duplication

Nine sites loop profiles around `mirai::everywhere()` with near-identical
scaffolding (loop, `tryCatch`/`try`, optional await via
`lapply(h, function(m) m[])`):

| Site | Body |
|------|------|
| scheduler.R:876-883 | read-daemon options + gdal config, awaited |
| scheduler.R:923-929 (`garry_pool_hygiene`) | `.daemon_hygiene`, awaited, error-tolerant |
| scheduler.R:1062-1071 | attach garry + ship read policy + run-start trim |
| scheduler.R:1087-1089 (on.exit) | `.daemon_shm_clear`, error-tolerant |
| scheduler.R:1612-1616 (`flush_drops`) | `.daemon_shm_drop`, error-tolerant |
| scheduler.R:1668-1675 / 1677-1680 | `.daemon_warm_jit`, targeted per profile |
| scheduler.R:2400-2402 | `.daemon_write_close`, awaited |
| composite_direct.R:385-392 (`.gd_daemon_prep`) | attach garry + gdal config + read_retry |
| composite_direct.R:588-591 | attach garry + `.gd_warm` |

Two consolidations:

1. `.pool_broadcast(profiles, expr-or-call, ..., await = FALSE,
   tolerant = FALSE)` in pools.R. Because every body is (or can be) a
   single `garry::.daemon_*()` call, it does not need NSE gymnastics:
   accept a function name plus args and build the `mirai::everywhere`
   call per profile. Collapses the loop + try + await boilerplate at all
   nine sites.
2. A `.daemon_setup(opts, gdal_config = FALSE, hygiene = FALSE, warm =
   FALSE)` daemon body absorbing the three "attach garry and set
   options" variants (scheduler.R:876-883, 1062-1071,
   composite_direct.R:385-392, 588-591), which today ship slightly
   different option subsets by accident of history. One body makes the
   shipped-option set auditable and lands in the ABI token for free.

Non-everywhere profile loops (`.garry_abi_check` scheduler.R:100-111,
pid collection 594-599 and 894-899) are fine as they are.

## R4. Duplicated host sink tail between the two executors

The post-drain tail of `execute_plan_mirai` (scheduler.R:2420-2496:
combine execution, multi-export assembly/write, single-sink
assembly/write) is a near-verbatim copy of `execute_plan`'s tail
(executor.R:633-696). The bodies differ only in how chunks are fetched
(`out[[st@id]]` vs `out_of(st)`/`combine_vals`). Sketch: extract
`.exec_sink_tail(plan, chunks_of, path, nodata, band_names)` in
executor.R where `chunks_of(stage)` is a caller-supplied accessor; both
executors call it. Roughly 60 duplicated lines each side, and it is the
code the equivalence suite exercises most directly, so the safety net is
strongest exactly here.

Same-shaped smaller duplication: `warp_only` is computed O(stages^2) in
executor.R:543-548 with per-stage `Filter` scans, while scheduler.R
already indexes consumers in one pass (1178-1197) precisely because the
Filter form was measured too slow. Extract `.plan_consumer_index(plan)`
returning `consumers_of` + `warp_only` and use it in both; executor.R
gets the O(n) form for free. The warp/source path-resolution block
(executor.R:555-568 vs scheduler.R:1283-1295) can join it as
`.stage_read_spec(graph, s)`.

## R5. execute_plan_mirai internal structure

The function accretes seven closure clusters over shared state. Ranked
by cohesion (how cleanly each extracts without breaking
closure-over-shared-state):

1. **Task build loop** (scheduler.R:1276-1567, ~290 lines). Writes into
   environments it (mostly) creates: `tasks`, `source_deps`,
   `source_elts`, `task_ins`, `store_users`, `task_stage_of`,
   `stage_store_mb`, `warm_specs`, `max_set_mb`. Reads `placement`,
   `use_raw`, `run_id`, `chunk_vals`, `prepare_fetch`. Extract as
   `.sched_build_tasks(plan, graph, placement, fetcher, use_raw,
   run_id, chunk_vals, opts)` returning one build-state environment.
   This alone drops the enclosing function to ~1,250 lines and gives
   every later cluster a named object to close over instead of a soup
   of locals.
2. **Fetch subsystem** (`prepare_fetch` scheduler.R:1112-1172 plus
   `fetch_state/made/files_of/reads_left` envs 1103-1110 and the eager
   cleanup at 2337-2350). Interacts with the rest only through
   `add_task` and task completion. Extract
   `.make_fetch_planner(run_id, fetch_mode, add_task)` exposing
   `$prepare(rpath, roo, nodata, grid)` and `$on_task_done(key)`.
3. **Store ledger** (`chunk_vals`, `task_ins`, `store_users`,
   `task_stage_of`, `host_keep`, `mb_store_resident`,
   `pending_drop(_mb)`, `queue_drop`/`flush_drops`/`release_store`,
   scheduler.R:1569-1640). One wrinkle: `flush_drops` reads the live
   `read_budget_mb`; pass an accessor. Extract
   `.make_store_ledger(profiles, run_id, budget_fn)` with `$queue`,
   `$flush(force)`, `$release(task)`, `$resident_mb()`, `$add_user`,
   `$keep(stage)`. The writer bookkeeping (`dispatch_write` /
   `harvest_writes`, 2067-2098) consumes only ledger operations plus
   `chunk_ref`, so it can become a method pair on the same object or a
   thin `.make_sink_writer(ledger, chunk_ref, wnodata)`.
4. **Routing state** (`prof_slots`, `prof_warm`, `prof_cold_busy`,
   `scan_profs`, `.pw_key`, `pick_comp_prof`, scheduler.R:973-1027;
   launch-side updates 2210-2215; completion-side updates 2292-2302;
   jit-miss invalidation 2256-2261). Fully self-contained state.
   Extract `.make_comp_router(comp_profs, routed, prof_depth,
   scan_profs)` with `$pick(t)`, `$on_launch(prof, t)`,
   `$on_done(prof, t)`, `$mark_warm(prof, ck)`, `$mark_cold(prof, ck)`.
   The three call sites in the drain loop become one-liners and the
   C2/C3 invariants (exact warmth, one cold compile per profile) get a
   single home that a unit test can drive without daemons.
5. **Chunk lookup** (`chunk_of`/`chunk_ref`/`sink_task_map`,
   scheduler.R:1693-1723). Pure functions over `source_deps`,
   `source_elts`, `chunk_vals`; they move with the build-state object
   from (1).
6. **Streaming-sink setup** (scheduler.R:1725-1815) and the drain loop
   itself (2152-2386): leave in place. After (1)-(5) the remainder is
   roughly: budgets, sinks, drain, tail; each section short enough to
   read.

Do (1) first and reassess; (2)-(4) are independent of each other and can
land as separate commits, each gated on the SI/composite equivalence
runs. Risk is medium only because closure extraction in R invites subtle
`<<-` scoping mistakes; the discipline is: every extracted cluster owns
its state env and exposes functions, nothing reaches back into the
enclosing frame.

## R6. composite_direct dispatch vs scheduler routing

`.gd_reduce_results` (composite_direct.R:551-653) re-implements a
miniature scheduler: `next_cp` round-robin over `.comp_profiles()`
(561-564), a warm-up broadcast loop (588-591), a FIFO in-flight cap with
`harvest()` (625-649), and `.gd_compute_cap` RAM admission (328-335).
Full unification with the scheduler's router is **not** worth it: the
pipeline's value is precisely that it skips task-table generality, and
its round-robin is correct because its kernels are uniform. Consolidate
only the seams:

- profile set and warm-up: the broadcast at 588-591 becomes
  `.pool_broadcast` (R3), and if the router object from R5 exposes a
  trivial `$next()` round-robin mode, `next_cp` can be deleted; keeping
  `next_cp` as-is is also defensible.
- `.gd_daemon_prep` merges into `.daemon_setup` (R3).
- `.gd_n_compute` / `.gd_pooled` move/die per R1.
- `.gd_fetch_errs`/`.gd_fetch_fail` (414-434) duplicate the scheduler's
  read_fail contract in miniature; fine to leave, but point their
  comment at the option rather than restating the policy.

## R7. Read-path payload assembly (gdal_adapter.R vs executor.R)

Three read paths share two hand-rolled conventions:

1. **nodata-to-NaN mapping**, three copies:
   `v[!is.na(v) & v == nodata] <- NaN; v[is.na(v) & !is.nan(v)] <- NaN`
   at gdal_adapter.R:170-173 (single-band), 213-214 (slab walk),
   449-450 (raw VRT numeric path). Extract `.read_nodata_to_nan(v,
   nodata)` next to the `.sv_*` family.
2. **raw-payload wrapping**: `structure(x, gdim = ..., gdt = "f32")` is
   constructed inline at gdal_adapter.R:224-226, 429, 430-431, 458,
   459-460 and executor.R:49-50 (the read-failure NaN fallback), while
   `.sv_from_vec` (executor.R:111-114) exists but only handles rank-2
   from a numeric vector. Sketch: add `.sv_wrap(raw, dims, gdt = "f32")`
   (attribute stamping only) and extend `.sv_from_vec` with an optional
   leading dim; route all six sites through them. The `.sv_*` layout
   contract (executor.R:88-96) then has exactly one producer surface.

The slab walk (`.gdal_read_window_bands`, gdal_adapter.R:189-228) and
`.raw_vrt_read` (400-464) intentionally differ in traversal and should
not be merged further; the shared piece is only sentinel mapping and
envelope stamping. `.exec_read_padded`'s NaN-fallback block
(executor.R:46-58) collapses to one `.sv_wrap`/array call after this.

Note the layout coupling: `.raw_vrt_parse` checks strides against
exactly the raw store payload layout, and `.raw_cube_create`
(gdal_adapter.R:240-262) + `stage_raw_cube` (280-316) both rebuild the
same VRT XML via `.raw_bsq_vrt_xml`; that part is already properly
factored. Any change here must bump `.garry_store_abi` only if byte
layout changes, which none of the above does.

## R8. options.R: two parallel tables

`.garry_defaults` (options.R:6-275) and `.garry_opt_info` (330-403) are
keyed by the same 36 names; every new option is added twice, and nothing
but convention keeps them aligned (`.garry_opt_check` silently skips a
default with no registry entry via `if (is.null(info)) next`, 439).
Merge into one table:

```r
.garry_opts <- list(
  chunk_target_px = list(
    default = 1e6, tier = "tuning", check = .opt_num(min = 1e-9),
    desc = "minimum pixels per compute chunk the planner aims for"),
  ...
)
```

with `.garry_defaults` and `.garry_opt_info` becoming derived views (or
better, `garry_opt`, `garry_options`, `.garry_opt_check` reading
`.garry_opts` directly). Drop the `is.null(info)` skip so an
unregistered option is a build-time error. The long narrative comments
above each default are the best documentation in the file; keep them
attached to the merged entries. Mechanical, low risk, and it makes
"option exists but is unvalidated" unrepresentable.

## R9. Dead legacy paths in the drain loop

`pooled <- TRUE` (scheduler.R:969) is a constant: `execute_plan_mirai`
errors without both pools (963-966), so the `!pooled` shared-bucket
branch (2163) and the `if (pooled)` guards (1655, 2167) are dead. Delete
the flag and flatten. Similarly `read_prof <- "garry_read"` (970) is a
constant alias used once meaningfully. Small, but this is exactly the
kind of superseded scaffolding the review asked about, and the launch
gate (2160-2193) is hard enough to read without a dead mode.

## R10. Error construction idiom

Counts across R/: 105 `cli_abort` call sites, 31 `.garry_error` sites, 2
bare `stop()` (executor.R:43 re-raise, scheduler.R:366 the deliberate
`garry_jit_miss` signal string; both fine). Of the `cli_abort` sites,
only two construct garry condition classes by hand
(scheduler.R:2088-2091 `garry_write_error`, 2269-2273
`garry_task_error`, both because they attach extra condition fields);
the other ~100 are unclassed. `.garry_error` itself lives in passes.R:23
for no structural reason.

Proposed idiom, deliberately cheap: (a) move `.garry_error` to a small
R/errors.R (or the top of options.R) and extend it to accept `...`
condition fields so the two hand-classed scheduler sites can use it; (b)
rule going forward: anything a caller might `tryCatch` on gets a class
via `.garry_error`; pure user-input validation stays plain `cli_abort`
(its bullet formatting is worth keeping). Do **not** rewrite the ~100
unclassed sites; that is churn with no consumer. The scheduler's
`garry_scheduler_error`, `garry_version_skew_error`, `garry_task_error`,
`garry_write_error`, `garry_option_error`, `garry_plan_error` classes
are already consistent in shape (`c(class, "garry_error")`), so nothing
is broken, only scattered.

## R11. Stale comments and docs drift (worst 10)

Superseded-behavior comments, ranked by how badly they mislead a new
reader. The routed-dispatch and raw-store work invalidated the premises
of several load-bearing comments:

1. collect.R:9: roxygen on `collect()` says "Execution arrives in
   Phase 5". The package's main entry point claims it cannot execute.
2. scheduler.R:829-830: the rationale for the `compute <- 2L` default
   states "mirai cannot route tasks to warmed daemons"; routed dispatch
   exists to do exactly that (`pick_comp_prof`, 995). The default may
   still be right, but the stated reason is no longer true.
3. scheduler.R:5-20 (file header): describes the inter-stage store as
   "one RDS file per (stage, chunk) in a tempdir". The store has been
   mori POSIX shared memory for several phases; the header documents a
   dead architecture.
4. scheduler.R:976-977: "exact per-kernel warmth and scan confinement
   arrive in C2/C3" five lines above the comment block describing C2/C3
   as implemented.
5. scheduler.R:2032-2034: "tasks cannot be routed, so 'may be cold' is
   conservative", directly above `if (routed) return(t$mb)`.
6. options.R:190-195 (`routed_dispatch` doc): promises warmth/confinement
   "in later stages" (shipped) and says "FALSE (the default until
   validated)" when validation is recorded in design/routed-dispatch.md
   and benchmarks; only the default flip is genuinely open.
7. scheduler.R:767-772 and 786-789 (`garry_daemons` roxygen): claims
   compute defaults to "enough narrow daemons to cover the machine ...
   falling back to TWO"; the code is unconditionally `compute <- 2L`
   (838). Also says scan kernels are never pre-warmed; routed mode
   pre-warms them at the designated profiles (1660-1675).
8. gdal_adapter.R:561-563 + executor.R:477-479,522:
   `gdal_create_output` and `.exec_write_sink` docs describe a
   GTiff-only sink; both now branch to the raw-BSQ cube on `.vrt`
   destinations. The exported entry point for the new format does not
   mention it.
9. scheduler.R:1252-1254 and 1457-1459: "first K = min(2, N)" and
   "K <= 2 designated scan profiles"; K is the tunable
   `garry_opt("scan_profiles")` whose own doc says to raise it.
10. plan.R:41 ("cpu until Phase 7"), executor.R:16-17 ("mirai
    distribution is Phase 7; GDAL write sinks are Phase 4b"),
    lazy_raster.R:425 ("reflect/wrap arrive with Phase 9"): phase-N
    forward references to shipped (or, for focal boundary modes,
    silently deferred) work. The lazy_raster one matters most: it
    promises a feature against a milestone that has passed, so a reader
    cannot tell deferral from bug.

Design-doc drift worth one commit: design/phase12c-raw-store.md:19,84
documents a `garry.store_values` option that does not exist (the shipped
mechanism is the `.g_has_raw_upload()` probe);
design/routed-dispatch.md:15,140 says C5/default-flip "stays open" while
its own later sections record C5 complete; phase11-roadmap.md:3-5 still
says garry lacks morphological mask cleanup.

These are one mechanical commit; pair it with R9.

## R12. Test suite (98 files, 4 helpers)

### Pool boilerplate: 72 setup sites in 34 files, no helper

There is no `helper-daemons.R`, `with_pools`, or setup/teardown file
anywhere. The five-line block (skips, `garry_daemons(N, M)`,
`on.exit(garry_daemons(0, 0), add = TRUE)`, an
`options(garry.chunk_target_px = ...)` + `on.exit(options(old))` pair)
repeats across the suite; representative copy at
tests/testthat/test-raw-store.R:36-49, with near-identical blocks in
test-mirai-equivalence.R:10-17, test-fetch-assemble.R:51-57,
test-fuse-wide.R:37-42, test-read-budget.R:38-41,
test-compute-on-read.R:44-48, test-placement.R:113-116,
test-store-residency.R:49-57 and ~20 more. Argument spread is small:
`(2, 1)` x29, `(2, 2, gdal_config = FALSE)` x21, `(2, 1, FALSE)` x12,
plus a handful of wider shapes.

Sketch: `with_pools(read, comp, code, gdal_config = TRUE, opts =
list())` in a new helper-daemons.R, implemented with
`withr::local_options` for the option list and guaranteed teardown.
Covers ~55 of the 72 sites. Sites that must stay bespoke: routed-profile
tests where `garry.routed_dispatch` must be set BEFORE pool creation and
teardown is itself an assertion (test-routed-dispatch.R:16-29 and
siblings; test-rss-correction.R:25-26), mid-body teardown/rebuild after
daemon kills (test-scheduler-failures.R:71-72), partial teardown of one
profile (test-writer-errors.R:72), deliberately-plain mirai pools
(test-mirai-pools.R:92-93, test-mirai-cuda.R:24-25), and
option-before-launch affinity tests (test-pool-affinity.R:50-53). The
helper should still take a pre-launch option list so the routed and
affinity families can adopt it. Bonus: it fixes a latent bug in
test-mirai-scaling.R:32-33, where `on.exit(..., add = TRUE)` inside a
`for` loop piles teardown handlers on the enclosing frame.

Same-shaped micro-duplication: a three-line `.with_chunk_px(px, code)`
wrapper is re-implemented under four names (test-multi-export.R:7-11,
test-scan-custom.R:9-13, test-plan-oracle-exec.R:5-9,
test-halo-propagation.R:9-13) plus inline variants; all are
`withr::local_options(garry.chunk_target_px = px)`, which other files
already use. Delete the wrappers.

### Fixture duplication: ~9 recipe families across 33 inline sites

helper-fixtures.R (5 memoised GTiffs) and helper-gti.R (`.gg_grid`,
`.gg_gti`, `.gg_masked_composite`) exist, but the dominant recipe, a
small EPSG:3857 f32/i16 raster at 10 m with origin (0, ny*10), is
re-rolled inline at 13 sites (test-reduce-band.R:5-12,
test-group-by-time.R:7-19, test-stac-harmonize.R:57-73,
test-handle-cache.R:9-18, test-dataset.R:186-194 and 263-267,
test-multiband-write.R:53-62, test-stage-merge.R:10-20,
test-write-roundtrip.R:52-61, test-lazy-map.R:23-34, test-stack.R:7-23,
test-stac-composite.R:12-30, test-raw-cube.R:10-25). Worst instances:
test-stage-merge.R:10-20 is byte-for-byte the `mk()` from
test-multiband-write.R:53-62 with a different filename prefix, and
test-stac-composite.R:12-30 is a literal copy of test-stack.R:7-23
including seeds and the shared `garry-fixture-t%d.tif` filenames, with a
comment admitting the cross-file coupling. Four more EPSG:32632 sites
re-derive `fixture_gradient_f32()`'s grid per slice
(test-focal-bilateral.R:81-89, test-scan-kalman-kfas.R:138-147,
test-gti.R:140-152, test-lazy-cog.R:318-327).

Sketch: parameterise `.gg_gti`'s tile writer into
`fixture_tif(nx, ny, values, dtype = "f32", crs = "EPSG:3857", res = 10,
nodata = NULL, tile = NULL)` in helper-fixtures.R and route recipe
families A and B (17 sites) through it. Two smaller wins: the tiled-COG
recipe (6 sites in test-lazy-cog.R plus test-stac-doc-items.R:16-26,
which duplicates `.lc_scog` exactly) gets a `fixture_cog()`; the
256x256 checkerboard + `buildOverviews` block duplicated verbatim
between test-fetch-assemble.R:110-120 and test-preview.R:128-137
(including its explanatory comment) becomes one memoised fixture, which
also halves the two overview builds that dominate both files.

### Overlap clusters (candidates for shared skeletons, not merges)

- Route equivalence: test-gd-general.R, test-composite-direct.R,
  test-route-matrix.R, test-routed-dispatch.R all implement
  build-GTI-cube / collect-single / collect-distributed / compare with
  private helpers (`.gg_equal`, `.rm_sweep`); each respin rebuilds the
  same fixtures. One shared `expect_routes_equal(x, routes)` helper
  would collapse them and cut fixture builds.
- The `pipelines <- list(map/focal/median/global/i16)` table appears
  verbatim in test-mirai-equivalence.R:22-54 and
  test-raw-store.R:50-72; hoist to a helper.
- The miniature benchmark graph (qa mask, focal cleanup, 2-band median)
  is copy-pasted between test-compute-on-read.R:17-32,
  test-placement.R:17-32 and test-placement-cost.R:20-31, each
  admitting the copy in a comment; hoist to helper-gti.R.

### Suspected slowest files (from structure; suite not run)

1. test-routed-dispatch.R: 8 pool spins for 7 tests, widths to (2, 4);
   ~40 fresh daemon processes each loading garry.
2. test-scheduler-failures.R: `Sys.sleep(5)` in the kill handler (:62),
   two 10 s poll loops, SIGKILL + pool rebuild.
3. test-composite-direct.R: 4 spins; every test rebuilds
   `.gg_masked_composite` (6 GTiffs + 3 GTIs); one test runs both
   gd_parallel arms.
4. test-route-matrix.R: `.rm_sweep` = 8 full collects per test, x3.
5. test-gd-general.R: three executions per assertion, fixtures rebuilt
   per test.
6. test-lazy-cog.R: two 512x512 multiband builds plus per-test tiles,
   10 distributed/single compares.
7. test-dataset.R: 22 collect() calls, 2 spins, two synthetic item sets.
8. test-halo-propagation.R: 18 compares at chunk_target_px = 300 (many
   chunks, ring recompute).

The common cost driver is pool churn plus per-test fixture rebuilds, so
R12's two helpers are also the speed lever: memoised fixtures and a
single spin per file (with_pools at file scope where tests permit)
attack items 1, 3, 4, 5 directly.
