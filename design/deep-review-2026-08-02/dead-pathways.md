# Dead and redundant pathway hunt (2026-08-02)

Scope: R/scheduler.R, R/composite_direct.R, R/gdal_adapter.R, R/lazy_cog.R,
R/executor.R, R/options.R, tests/. Every claim carries file:line evidence from
the code as it stands on `placement-pass`. Findings are ranked at the end by
(lines removed x confidence).

## Summary of verdicts

| # | Finding | Verdict | Net deletion |
|---|---------|---------|--------------|
| 1 | `pooled <- TRUE` constant and its dead arms | delete now | ~15-20 lines |
| 2 | Legacy anonymous-pool machinery | keep until the routed default flip, then excise | ~120-150 lines + 1 option |
| 3 | `writer_on = FALSE` host-inline fallback | keep (tested resilience path) | 0 |
| 4 | jit-miss resend for read-slot tasks | confirmed dead-but-harmless; nothing to delete | 0 |
| 5 | `.execute_gd_general` production orphan; `gd_compute_budget` inert | delete `.gd_compute_band` now; decide on gd_general and the budget option | ~25-80 lines |
| 6 | fetch/assemble split | live in production (scheduler-route scans, multi-export); `force` is test-only by design | 0 |
| 7 | lazy_cog CK staging vs raw-cube format | partial overlap; unification is an extension, not a deletion | 0 now |
| 8 | `use_raw = FALSE` doubles-store arm | keep: it is the released-anvl compat path | 0 |
| 9 | Tests exercising only superseded behavior | none fully; test-gd-general.R partially | small |

## 1. `pooled <- TRUE`: the constant and its unreachable arms

`pooled` is assigned the constant `TRUE` at R/scheduler.R:969 and never
reassigned (all uses: 969, 1655, 2163, 2167). It became constant at commit
cc8124b ("Require the garry daemon pools for distributed execution"), which
made `execute_plan_mirai` refuse to run without the split pools
(R/scheduler.R:963-966); the single-shared-pool mode it used to select has no
entry point left.

Dead arms and stale text:

- R/scheduler.R:2163 `if (!pooled && length(inflight) >= cap_read) break`:
  the single-pool shared-bucket launch cap. Unreachable.
- R/scheduler.R:2167 `if (pooled) {` ... `}` (2167-2193): the wrapper is
  always entered; the implicit fall-through (launch without pool-specific
  gates) is unreachable. The block body can be unindented into the loop.
- R/scheduler.R:1655 `if (pooled && isTRUE(garry_opt("jit_warmup")) ...)`:
  the `pooled &&` conjunct is vacuous.
- Stale comments describing the two-mode split: R/scheduler.R:1031-1037
  ("Single pool: one shared bucket (unchanged behavior)"), 1268 ("pooled
  mode"), 1642-1648 ("Only in pooled mode: on a shared pool the warm task
  would displace a read"), 2160-2162 ("Single pool: one shared bucket
  (pre-pool behavior)").
- Same staleness outside the scheduler: R/composite_direct.R:253-257 and
  489-494 reason about "a single pool", but `.cd_spec` is only ever called
  from the distributed branch of collect() (R/collect.R:86-90), which
  requires `garry_daemons_set()`; a single pool cannot reach it. Consequently
  `.gd_pooled()` (R/composite_direct.R:321) is constant TRUE at its only call
  site (R/composite_direct.R:265). options.R:165-170 (`gd_parallel` doc)
  repeats the single-pool story.

Deleting simplifies the launch scan to one shape: per-pool slot gates plus
byte budgets, no vestigial shared bucket. Risk: none; the arms are provably
unreachable and the full suite runs through the pooled arms already.

## 2. Legacy anonymous-pool machinery (reachable only via `routed_dispatch = FALSE`)

`routed_dispatch` currently defaults to FALSE (R/options.R:196), so today the
legacy machinery is the ambient default and none of this is dead yet. The
question is what goes when the default flips. design/routed-dispatch.md
records C1-C3 landed and validated decisively (SI crop=2048: routed c6 399.8 s
vs anonymous best 552.2 s, two anonymous width-4 OOMs; width saturates at 6;
"the drain itself is done"), with one gate open: "Remaining before the default
flip: the bc-cohort box sweep ... user-driven".

The legacy-only code, all guarded by `!routed` (`routed` defined at
R/scheduler.R:978):

- **Pool creation arm**: `mirai::daemons(compute, .compute = "garry_compute")`
  (R/scheduler.R:863-865) and the `.comp_profiles()` fallback string
  (R/scheduler.R:584-586). `prof_depth` legacy width calc at 979.
- **Cold-kernel slow-start ramp**: comment block and envs at
  R/scheduler.R:2100-2109 (`ck_inflight`, `ck_done`), the launch gate at
  2183-2187, increments at 2195-2196, decrement/count at 2283-2287. In routed
  mode the counters are still maintained but gate nothing (mb_eff returns
  early, the ramp check is `!routed`-guarded), i.e. they are already pure
  overhead per task in routed runs.
- **`scan_compile_mb` surcharge in `mb_eff`**: R/scheduler.R:2037-2045; the
  legacy arm is 2043-2044. The option itself (options.R:255-269, registry
  399-400) is calibration-tier and carries the 10000 MB conservative value
  (the briefly-shipped 1500 recalibration was reverted after a 42G scope
  kill; see the option comment). Caveat for excision: the VALUE is
  legacy-only, but `cold_mb > 0` doubles as the "is a cold scan" marker in
  routed mode (pick_comp_prof at 996, prof_cold_busy at 2212-2214,
  2300-2301). Removing the option means replacing `cold_mb` with a boolean
  scan flag on the task, set from `has_scan` at R/scheduler.R:1529-1531.
- **Pool-wide `warmed_ck`**: env at 1654, populated only in the legacy
  broadcast arm 1676-1681; consulted at 2043 (mb_eff), 2185 (ramp), 2205
  (key-only launch), cleared at 2256-2258 (a no-op in routed mode, where
  warmth lives in `prof_warm`). All of it goes with legacy mode.
- **"Scan warm-up only on pools <= 2" gate**: R/scheduler.R:1460-1469,
  `if (!has_scan || n_comp <= 2L || routed)`. Routed pools take scan specs at
  any width (targeted broadcast to the K scan profiles, 1660-1675), so after
  the flip the condition collapses to nothing and the ten-line comment goes.
- **Stale prose**: the `garry_daemons()` docs still sell "cold-kernel slow
  start, scan-compile surcharge" as the safety mechanisms (R/scheduler.R:
  798-805, 826-837); design comments at 986-990 already describe them as
  replaced in routed mode.

**Test coverage**: no test sets `routed_dispatch = FALSE` explicitly; the
legacy path is exercised only as the ambient default
(tests/testthat/test-routed-dispatch.R pins TRUE per test; the C5 note in
design/routed-dispatch.md ran the whole suite flipped). After a default flip,
legacy mode would have zero coverage unless a test pins it, which is the
classic recipe for a rotting escape hatch.

**Recommendation**: keep as the escape hatch exactly until the bc-cohort
sweep lands, since that is the one stated gate and the two modes share every
other seam by construction (`.comp_profiles()` loops). At the flip, excise
rather than retain: the legacy mode's admission story (probabilistic ramp,
byte surcharge) was twice miscalibrated in the field (design/routed-dispatch.md
cites both), so as an untested escape hatch it is a liability, not insurance.
Excision deletes ~120-150 lines across the items above, the `scan_compile_mb`
option, and no test files (add one line to test-options-registry.R for the
removed option).

## 3. `writer_on = FALSE` host-inline streamed write: keep

`writer_on` is FALSE only when the `garry_write` profile has no daemons
(R/scheduler.R:1740-1741). `garry_daemons()` always creates the writer
whenever either pool exists (R/scheduler.R:871-872), so under the blessed
setup the fallback never runs. It remains reachable three ways:

1. Manual writer teardown, which tests/testthat/test-writer-errors.R:68-80
   does deliberately (`mirai::daemons(0, .compute = "garry_write")`) and
   asserts oracle-identical output.
2. A writer daemon that died before run start: the `tryCatch(... error =
   FALSE)` at 1741 converts a dead profile into writer_on = FALSE instead of
   an abort.
3. Pools assembled by hand with `mirai::daemons()` under the garry profile
   names: `garry_daemons_set()` (R/scheduler.R:942-944) checks only read and
   compute, so a writer-less pool set is a legal public state.

The fallback's whole footprint is the two inline-else arms
(R/scheduler.R:2312-2317, 2327-2332) plus keeping `sink_ds`/`sp$ds` open when
no writer exists (1756-1766, 1783-1785). Roughly 20 lines, now tested, and it
is the only thing standing between "the singleton writer is down" and a failed
run. Assuming the writer (and erroring when absent) would save those lines at
the cost of turning a degraded mode into a hard failure. Keep.

## 4. jit-miss resend for read-slot tasks: confirmed dead, confirmed harmless

`garry_jit_miss` is raised in exactly one place: `.daemon_run_compute_shm`
when `fn` is NULL and the cache is cold (R/scheduler.R:361-366). Read-pool
tasks can never launch key-only: `warm_now` requires `slot == "comp"`
(R/scheduler.R:2203-2206), so a read task with a `ck` (a fused read) always
ships its closure, and the read task body (`.daemon_run_source_shm` ->
`.apply_fuse`, R/scheduler.R:159-166, 204-238) compiles from `fuse$fn`
unconditionally with no miss path. The resend handler at 2247-2267 is a
single shared branch, not a per-slot one; the read-task case simply cannot
enter it. This matches design/deep-review-2026-07-31/defect-hunt.md
("Read-pool tasks cannot raise garry_jit_miss ... dead but harmless").
Nothing to delete; the branch is load-bearing for compute tasks.

## 5. composite_direct route overlap

Route selection is `.cd_spec` -> `.gd_decompose` -> scheduler
(R/collect.R:90-107). Arm map under option combinations (composite_direct =
TRUE, pools up, patched anvl assumed):

| Plan | gd_parallel | weight vs budget | Route / arm |
|---|---|---|---|
| pure composite, multi-band | TRUE (default) | any | `.execute_composite_pipeline` (composite_direct.R:495-496) |
| pure composite, single-band | any | any | whole-grid lean arm in the HOST process (composite_direct.R:498-529) |
| pure composite, multi-band | FALSE | <= budget | whole-grid lean arm |
| pure composite, multi-band | FALSE | > budget | `.cd_spec` refuses (265-266) -> `.gd_decompose` -> **gd_reduce** (test-composite-direct.R:44-58) |
| pure composite, single-band | FALSE | > budget | `.cd_spec` refuses -> `.gd_decompose` NULL (no upper IR, composite_direct.R:795-797) -> scheduler |
| reduce-structured with upper IR | any | n/a | gd_reduce |
| scan / warp / unrecognised IR | any | n/a | scheduler (ScanNode fails `ok_type`, composite_direct.R:686-689) |

Findings:

- **The whole-grid lean arm is still reachable in production**, but only for
  single-band composites: `parallel <- isTRUE(gd_parallel) && n_bands > 1L`
  (composite_direct.R:488) is FALSE for one band regardless of options. It is
  not dead; it is the single-band default.
- **`gd_compute_budget` is inert under defaults.** The fall-through condition
  (composite_direct.R:265-266) requires `!isTRUE(garry_opt("gd_parallel"))`,
  and gd_parallel defaults TRUE (options.R:171). `.gd_pooled()` in the same
  conjunction is constant TRUE (finding 1). So under defaults the budget is
  never consulted, and when it IS activated (gd_parallel = FALSE) the
  multi-band fall-through lands on gd_reduce, whose `.gd_reduce_results`
  (composite_direct.R:551-653) is the same overlapped parallel pipeline the
  user just opted out of. The option's stated purpose, "re-enables the
  scheduler route for heavy composites" (options.R:169-170), has been
  obsoleted by commit bdccbbe (reduce-decomposition): only the single-band
  heavy case still reaches the scheduler through it. test-composite-direct.R:
  50-52 documents the shadowing explicitly.
- **Latent flag, not dead code**: because the fall-through also requires
  `!gd_parallel`, a HEAVY single-band composite under defaults runs the
  whole-grid arm in the host process with no size guard at all; the budget
  was the guard and it is switched off exactly where the memory-heavy arm
  still runs. Worth a decision: either delete the budget (and accept
  whole-grid-always for matched single-band shapes), or repair the condition
  to consult the budget for the `parallel == FALSE` arm regardless of the
  gd_parallel option.
- **`.execute_gd_general` is a production orphan.** Its only callers are
  tests (tests/testthat/test-gd-general.R:31); collect() routes to
  `.execute_gd_reduce` (R/collect.R:104) and nothing else references it. The
  header comment (composite_direct.R:655-665, "the single path for any
  warp-on-read-eligible plan") describes a role bdccbbe took away. `.gd_spec`
  itself stays: it is `.gd_decompose`'s gate (composite_direct.R:775).
  Deleting `.execute_gd_general` (composite_direct.R:701-739, ~39 lines)
  costs the test suite its whole-grid-vs-decomposed byte-identity oracle
  (test-gd-general.R uses it as the anchor both routes are compared against);
  the scheduler equivalence check in the same test survives. Defensible
  either way; if kept, rewrite the stale header.
- **`.gd_compute_band` is fully dead.** Defined at composite_direct.R:75-98
  ("parallel compute spike" task body), exported for daemon dispatch, called
  by nothing in R/, tests/, or benchmarks/. Superseded by the pipeline pair
  `.gd_compute_mask` / `.gd_compute_masked_band` (composite_direct.R:106-144).
  Delete: ~24 lines plus the NAMESPACE entry. Risk: none.

## 6. Staged fetch/assemble split vs composite_direct's warp path

`prepare_fetch` (R/scheduler.R:1112-1172, wired at 1318-1334) is reachable
only inside `execute_plan_mirai`, for `source_read` stages whose path is
`GTI:` with a `.meta.rds` sidecar and `/vsi*` locations (1113-1124). Since
composite-shaped remote-GTI plans are captured by composite_direct/gd_reduce
(which do their own warp-on-read via `.cd_fetch_warp`,
composite_direct.R:289-311, no fetch/assemble), the production population
still reaching prepare_fetch is:

- scan-bearing GTI plans (ScanNode fails `.gd_spec`'s `ok_type`,
  composite_direct.R:686-689): the SI smoother/tail workload, which is the
  package's flagship scheduler workload;
- multi-export plans (always `execute_plan_mirai`, R/collect.R:52-58);
- any plan with Warp/Fused nodes or unrecognised IR, `composite_direct =
  FALSE`, or unpatched anvl (`.g_has_raw_upload()` FALSE fails both specs at
  composite_direct.R:217 and 671).

So the split is alive and load-bearing; not a removal candidate. `fetch =
"force"` (fetch local sources too) is exercised only by
tests/testthat/test-fetch-assemble.R:55,88 and documented as "testing;
staging slow filesystems" (options.R:127-128). Test-only in practice, by
design; harmless to keep as the offline test lever for the split.

## 7. lazy_cog CK staging vs the raw-cube format

Both stage `.bin + VRTRawRasterBand .vrt` and both generate the XML with the
same function, `.raw_bsq_vrt_xml` (lazy_cog's `.stage_buffer` at
R/lazy_cog.R:315-326; the raw-cube writers at R/gdal_adapter.R:240-262,
280-316). Whether a staged lazy_cog output already rides the new fast read
(`gdal_read_window`'s raw-VRT branch, R/gdal_adapter.R:158-163) depends on
`.raw_vrt_parse` (R/gdal_adapter.R:345-393), which requires uniform
**Float32/Float64** bands (360-361), exact BSQ strides, and a sibling bin.

- A lone CK set staged from a float source: parses, already reads through the
  fast path (same generator, same strides; CK source nodes carry no
  open_options, so the 158 gate passes). No work needed.
- The common cases do NOT hit it: AEF/embedding stacks stage at native
  integer dtype (Int8/Int16; `.lazy_cog_single` reads at native dtype,
  R/lazy_cog.R:120-131, and `.stage_buffer` writes `res$dtype`), and
  `.raw_vrt_parse` rejects non-float. Batched time-series sets are wrapped in
  a nested mosaic VRT (`.ck_mosaic_pinned` -> `gdal_mosaic_vrt`,
  R/lazy_cog.R:282-288), which is a regular VRT, not a VRTRawRasterBand
  document, so it falls to the GDAL path by construction.

Unification is therefore an extension of the reader, not a deletion:
generalise `.raw_vrt_parse`/`.raw_vrt_read` to the integer dtypes
(size/signed readBin, sentinel mapping already present at
gdal_adapter.R:449-450) and the single-tile mosaic case. The 9x measured win
(gdal_adapter.R:151-157) applies squarely to the AEF 64-band staging reads,
so this is a performance opportunity with real upside; there is no redundant
code to remove on the lazy_cog side, since the staging formats are already
literally the same format.

## 8. The doubles (non-raw) store path

`.exec_use_raw_store()` is exactly `.g_has_raw_upload()`
(R/executor.R:263), a capability probe: does the installed anvl accept raw
byte payloads (R/ops.R:116-125)? It is FALSE precisely on released upstream
anvl (the raw-payload patch lives on the local branch awaiting review; the
probe comment at ops.R:104-106 says so). It is not an option and cannot be
toggled; on Hugh's boxes it is always TRUE.

Code riding only the FALSE arm: the doubles store transport
(`.sv_download_exports`'s early return, R/executor.R:238; the `g_download`
arms), `.store_bytes_of`'s 8-byte pricing for f32 (R/scheduler.R:651-653),
the `raw_in = FALSE` matrix read shape (R/scheduler.R:1307-1312), and the
`out = "matrix"` branches of the readers. But note: the matrix/doubles code
is NOT exclusively the FALSE arm; the single-threaded oracle always uses
doubles (executor.R:259-262), non-f32 dtypes keep the matrix path even when
use_raw is TRUE (D21 gate, scheduler.R:1306-1312), and f64 regions are 8-byte
either way. What is genuinely FALSE-arm-only is small: the doubles pricing of
f32 regions and the `store_raw = FALSE` download shape. Verdict: keep. This
is the compatibility path for every user on released anvl (where
composite_direct is also disabled by the same probe,
composite_direct.R:217/671, so the scheduler-with-doubles is their ONLY
distributed path). Revisit only if/when the anvl patches ship upstream and a
minimum anvl version is declared.

## 9. Tests exercising only superseded behavior

Swept all 90 test files. None is wholly superseded:

- tests/testthat/test-gd-general.R is the closest: its
  `.execute_gd_general` assertions (line 31) are the only reason that
  function exists (finding 5). The rest of the file (scheduler equivalence,
  `.gd_decompose` gates) is live. If gd_general is deleted, this file shrinks
  rather than dies.
- tests/testthat/test-fetch-assemble.R exercises a production path through a
  test-only option value ("force"); live (finding 6).
- tests/testthat/test-jit-key-only.R tests the `garry_jit_miss` signal, which
  both modes use (routed resends are per-profile-exact, scheduler.R:2259-2266).
  Live.
- test-mirai-pools.R / test-launch-order.R / test-mem-admission.R /
  test-read-budget.R / test-route-matrix.R / test-raw-store.R /
  test-raw-cube.R all gate current machinery (checked headers and bodies).
- No test pins `routed_dispatch = FALSE`, which is the coverage gap flagged
  in finding 2, not a superseded test.

## Ranking by (lines removed x confidence)

1. **Legacy anonymous-pool machinery** (finding 2): ~120-150 lines + the
   `scan_compile_mb` option. Confidence high on the code being routed-mode
   dead, but gated on the pending default flip (bc-cohort sweep). Action:
   schedule the excision as part of the flip commit, not before.
2. **`.gd_compute_band`** (finding 5): ~24 lines, certain, zero risk. Delete
   now.
3. **`pooled` constant + arms + stale single-pool comments** (finding 1):
   ~15-20 lines plus comment hygiene across three files, certain, zero risk.
   Delete now.
4. **`gd_compute_budget` + `.gd_pooled()` conjunct** (finding 5): ~15 lines +
   option + registry entry + one test rewrite (test-composite-direct.R:44-58
   becomes a gd_parallel=FALSE fall-through test or is deleted). Confidence
   high that the current semantics are not the documented ones; requires a
   decision on the heavy single-band guard before deleting.
5. **`.execute_gd_general`** (finding 5): ~39 lines + stale header, but it is
   the test suite's byte-identity oracle for gd_reduce. Medium confidence
   that removal is right; cheap to keep with a corrected header.
6. **Everything else** (findings 3, 4, 6, 7, 8, 9): keep; finding 7 is an
   extension opportunity (raw reader for integer dtypes) rather than a
   removal.
