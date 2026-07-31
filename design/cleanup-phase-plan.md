# Cleanup phase plan: the deep-review consolidation backlog

STATUS 2026-08-02: ALL FIVE STAGES LANDED (D1 3381fbb, D2 with D4/D3
following, D5 last), each gated green; the ABI token hashed
identically across the D1 split and the D4 merge was gated on
byte-identical defaults. D5 converted 68 pool-boilerplate sites and
unified the chunk-px wrapper; the ~9 fixture recipe families remain
as incremental follow-up.

Date: 2026-08-02. Successor to `design/deep-review-2026-08-02/`
(waves 1-2a landed: routing-only dispatch, decisive defaults, dead-arm
excision, ABI enrollment, stale-doc sweep). This phase is the
structure-only remainder from `refactor-map.md`, scoped so each stage
lands green independently. Safety net: the full suite (both the
equivalence gates and the routed-dispatch/failure suites); no stage
changes observable behavior.

Two design questions were probed 2026-08-02 and are settled:

- **Broadcast NSE**: `do.call(mirai::everywhere, list(expr, args...,
  .compute = p))` with `expr` a language object evaluates remotely and
  ships the args (probed: state lands, value returns). The first
  `.pool_broadcast` attempt used a nonexistent `.expr_quoted` argument
  and was backed out; do.call is the correct mechanism.
- **Collation**: roxygen `@include` chains support the split as
  `executor.R -> daemon.R -> pools.R -> scheduler.R -> placement.R`
  (daemon bodies call `.exec_*`/`.sv_*`; pools call the ABI token;
  the scheduler calls both).

## Stage D1 — file split (pure moves, biggest legibility win)

scheduler.R (~2,300 lines post-excision) becomes three files:

- **daemon.R**: every cross-process body — the `.daemon_*` family,
  composite_direct's `.cd_fetch_warp` / `.gd_warm` /
  `.gd_compute_mask` / `.gd_compute_masked_band` (moved here, KEEPING
  their names so the ABI hash's explicit enrollment list from wave 1
  keeps matching), `.daemon_hygiene`, `.garry_malloc_trim`, the ABI
  token/check, and the daemon-side caches (`.daemon_cache`,
  `.daemon_shm`, `.daemon_ds`).
- **pools.R**: machine probes (`.garry_cores`, RAM/cgroup/shm/anon
  helpers), `.comp_profiles`/`.comp_n`/`.garry_pool_pids`, affinity +
  `.comp_pool_shape`, `garry_daemons`, `garry_pool_hygiene`,
  `garry_daemons_set`, `.garry_state`.
- **scheduler.R**: `execute_plan_mirai` and its closures only.

Rules: no function bodies change; `@include` headers and NAMESPACE
regenerate; the ABI token must hash IDENTICALLY before/after (assert
in the stage's test: record the token pre-split in a scratch file,
compare post-split — daemons from the same install must not see a
skew they'd refuse).

Size: ~0 net lines, high churn. Gate: full suite + token equality.

## Stage D2 — `.pool_broadcast()` (the probed design)

```r
.pool_broadcast <- function(expr, profiles = .comp_profiles(), ...,
                            await = TRUE, quiet = FALSE) {
  # expr is a LANGUAGE OBJECT (quote(...)); do.call defeats
  # everywhere()'s NSE so one quoted body serves every profile
  args <- c(list(expr), list(...))
  out <- list()
  for (p in profiles) {
    h <- if (quiet) tryCatch(
      do.call(mirai::everywhere, c(args, list(.compute = p))),
      error = function(e) NULL)
    else do.call(mirai::everywhere, c(args, list(.compute = p)))
    if (await && !is.null(h)) out <- c(out, lapply(h, function(m) m[]))
    else if (!is.null(h)) out <- c(out, h)
  }
  invisible(out)
}
```

Converts (from refactor-map R4): the option-ship + run-start hygiene
loop, the targeted warm-up loop (profiles argument = the per-profile
spec subsets, so it stays a caller loop with the helper doing one
profile — or the helper grows a `spec_of(p)` hook; decide at
implementation by which reads better), `garry_pool_hygiene`,
`.gd_daemon_prep`, pid collection, the ABI check's per-profile mirai.
Sites that ship different args per profile stay explicit loops.

Size: ~40 lines added, ~60 removed. Gate: routed-dispatch + hygiene +
ABI suites.

## Stage D3 — sink-tail dedup + executor index port

Two near-verbatim copies diverging silently:

- The post-drain host assembly (scheduler.R, end of
  execute_plan_mirai) mirrors executor.R's sink assembly. Extract
  `.exec_assemble_sinks(stage_chunks_fn, plan, path, nodata,
  band_names)` where `stage_chunks_fn(sid, j)` abstracts chunk lookup
  (`chunk_of` in the scheduler, the stage list in the executor). The
  H1 defect class (silent NULL chunks) gets ONE guard instead of two.
- executor.R still computes `warp_only` with the O(stages^2) Filter
  scan the scheduler replaced with a one-pass consumer index
  (`.placement_scan` exists and is shared by placement — port the
  executor to it; delete the local scan).

Size: ~-80 lines. Gate: multi-export, write-roundtrip, nodata-e2e,
route matrix (written arms), plus the oracle-vs-scheduler equivalence
files — this touches the exact seam H1 lived in, so run the
`list(raw = x, derived = f(x))` regression explicitly.

## Stage D4 — options single table

Merge `.garry_defaults` + `.garry_opt_info` into one
`.garry_options_table` (name, default, tier, check, desc);
`garry_opt`, `garry_options()`, `.garry_opt_check()` read from it.
Registry test collapses to internal-consistency of one structure.
Size: ~-60 lines. Gate: options-registry suite.

## Stage D5 — test-suite consolidation

From refactor-map R7 (pre-wave counts): 72 pool spin/teardown sites in
34 files; ~55 convertible to

```r
with_pools <- function(read, compute, code, ...) {
  garry_daemons(read, compute, gdal_config = FALSE, ...)
  withr::defer(garry_daemons(0, 0, gdal_config = FALSE))
  force(code)
}
```

(helper-pools.R; the bespoke sites — kill/rebuild, partial teardown,
routed-profile assertions — stay explicit). Fixture consolidation:
the ~9 inline GTiff recipe families fold into helper-fixtures.R /
helper-gti.R generators; the four copies of the chunk-px wrapper
become one helper. Convert incrementally, one test file cluster per
commit, suite after each cluster.

Size: ~-300 test lines. Gate: full suite per cluster.

## Ordering and estimates

| stage | size | risk | prereq |
|---|---|---|---|
| D1 file split | 1 session | low (pure moves + token gate) | — |
| D2 broadcast | small | low (probed) | D1 (helper lives in pools.R) |
| D3 sink dedup + index port | 1 session | MEDIUM (H1 seam) | none, but after D1 for file placement |
| D4 options table | small | low | — |
| D5 test consolidation | 1-2 sessions, mechanical | low | — |

Parked beyond this phase (unchanged from the synthesis): the
error-idiom rule (define, don't rewrite), execute_plan_mirai's
task-build extraction (only with better memory-behavior coverage
first), lazy_cog raw fast-path extension to Int8/mosaic staging
(feature work), the `read` default fast-link composite A/B, and
`ram_budget_mb`'s misleading name (breaking rename, needs a
deprecation cycle).
