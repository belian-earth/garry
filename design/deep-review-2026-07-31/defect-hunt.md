# Defect hunt: placement / topology / writer / f64 subsystem

Adversarial correctness review of `scan-node..placement-pass` (25 commits), 2026-07-31.
Method: full diff read, final-state read of R/scheduler.R, R/placement.R, R/passes.R,
R/band_mlp.R, R/executor.R, R/options.R, R/gdal_adapter.R; concrete interleaving analysis
of the seven risk areas; live repros against the installed package (scripts and observed
output in the appendix). Findings ordered by severity. Line numbers refer to the
placement-pass tips of the named files.

## Summary

| id | sev | area | one-liner |
|----|-----|------|-----------|
| H1 | high | placement + chunk retrieval | A source that is itself a requested sink returns NULL in memory and writes an all-zero file, silently. Fused variant is new and default-reachable under cost mode; unfused split variant predates the range but the in-range fused-aware rework did not close it. Reproduced. |
| M1 | med | sv store | `.sv_trim` index arithmetic overflows R integers on payloads over 2 GiB and silently zero-fills the output; f64 (8 B elements) halves the threshold. Overflow semantics verified live. |
| M2 | med | cold-kernel slow start | `warmed_ck` is set optimistically before the async warm-up resolves; a failed scan warm-up (the OOM-prone case) then bypasses both the slow-start ramp and the `cold_mb` surcharge on the jit-miss resend path. |
| L1 | low | admission | `comp_ok`'s `compute_inflight` count cap rejects fused READ tasks against the compute-tag in-flight count they never contribute to. Throttling only. |
| L2 | low | store accounting | `.exec_mask_edge` materialises raw payloads on edge chunks with `out_pad > 0`; an f32 region then resides as R doubles while the budget books 4 B/px. |
| L3 | low | writer error path | On abort, `on.exit` runs `.daemon_shm_clear` before `.daemon_write_close`, so queued writer tasks map already-unlinked regions and fail noisily after the run has already failed. |
| L4 | low | cost model | `.plan_read_px`, `.stage_fuse_act_bytes_px` and the placement `move_mb` price 4 B/px unconditionally; f64 chains are under-priced 2x. Estimates only; admission floors absorb it. |
| L5 | low | pool shaping | `.comp_pool_shape` can leave the pool half re-masked with stale `comp_threads` if `taskset` fails mid-loop; state and masks then disagree until the next successful re-mask. |

Verified clean (suspicions checked against the code and discarded): writer refcount
discipline, resend accounting symmetry, ramp deadlock, f64 write demotion, mixed-dtype
writer, combine-plus-fused-sink coexistence, rank-3 export pricing, the k >= 2 affinity
floor, and the drain-end flush ordering. Details in "Checked and clean" below.

---

## H1: source-as-sink multi-export silently loses the raw band

**Severity: high.** Silent wrong output (NULL in memory, an all-zero file on disk), no
error, on a legitimate user shape.

**Scenario.** A multi-export collect that requests a source band alongside a product
derived from it, where the derived chain is the source's only compute consumer:

```r
x <- lazy_source(f, band = 1L, graph = g)
y <- lazy_map(x, fn = function(v) v * 2)
collect(list(raw = x, doubled = y), ...)   # distributed
```

**Observed (repro1/repro1b, appendix).** Under the default `placement = "cost"` with
pools up: `res$raw` is `NULL` (no error); with `path=`, `raw.tif` is created and never
written (reads back zeros, corner 0 vs expected 101) while `doubled.tif` is correct. The
task log shows one read task `s1_r1` and a single `write` event (the fused doubled sink);
no write for raw and no failure. Under `placement = "rules"` (repro1c) the fused route is
avoided but `res$raw` is still `NULL`.

**Mechanism.** Two independent holes, one shared root: the raw sink's chunks are looked
up by keys that no task produced.

1. *Fused (new in range, default-reachable).* `.placement_candidates`
   (R/placement.R:56-70) flags only the COMPUTE stage as `sinkful` (line 67); it never
   checks whether the SOURCE stage `S` is itself in `plan@sinks`. Cost mode ignores
   `sinkful` entirely (intended, since fused sinks stream), so the chain fuses and the
   read tasks store only `fspec$out_key`, the kernel's export. The source window is never
   stored at all, so no retrieval fix can recover it: fusion is simply wrong here.
   `host_keep[[.key(S@id)]]` set at R/scheduler.R:1476-1484 protects nothing, because the
   read tasks' `task_stage_of` is the fused `oid = C@id`.

2. *Unfused split (predates the range; left open by the in-range rework).* When `S` has a
   compute consumer, `.exec_split_cg` usually makes it a coarse split read with tasks
   keyed `s{sid}_r{r}` and per-chunk elements in `source_elts`. `chunk_of` /
   `chunk_ref` / `sink_task_map` (R/scheduler.R:1369-1402) consult
   `source_deps`/`source_elts` only when `fused_cid[[.key(sid)]]` is TRUE; for the
   unfused split source they fall through to `chunk_vals[["s{sid}_c{j}"]]`, which never
   exists, yielding NULL chunks and a `sink_task_map` whose keys match no completing
   task, so the streaming writer never fires and the drain "succeeds". The comment at
   line 1367 ("gate on the placement table, not on the env") defends the gate, but for an
   unfused split source `source_deps`/`source_elts` hold exactly the correct mapping
   (it is what compute consumers use); the gate protects nothing. The old scan-node
   `read_chunk` had the same `s%d_c%d` lookup, so this half is pre-existing, but commit
   312a0e4 made sinks placement-eligible on the strength of "fused-aware chunk lookup"
   and 681d534 made cost mode the default; together they widened the exposure and the
   invariant claimed at R/scheduler.R:1913 ("sink/combine stages are never split-read
   sources") is false precisely for this shape.

Downstream damage is mode-dependent: in-memory returns NULL for that export; with a path,
`gdal_create_output` leaves a zero-filled file that reads as valid data.

**Fix sketch.**
1. In `.placement_candidates`, refuse the candidate when the source is a requested sink:
   `if (any(plan@sinks %in% S@members) || plan@sink == S@id) next` (mirrors the
   `warp_only` guard at R/scheduler.R:899-901).
2. In `chunk_of`, `chunk_ref` and `sink_task_map`, drop the `fused_cid` gate and consult
   `source_deps`/`source_elts` whenever populated; for aligned unfused sources they are
   absent and the direct lookup still applies.
3. Add a regression test for `list(raw = x, derived = f(x))` in both modes, in-memory and
   to path. Consider also making retrieval fail loudly on a NULL chunk
   (`.exec_check_writable(NULL, n)` currently passes for `n > 1`).

## M1: `.sv_trim` integer overflow silently zero-fills payloads over 2 GiB

**Severity: medium.** Silent data corruption; the trigger is size-dependent.

R/executor.R:149-179. The gather indices are built in integer arithmetic:
`rows0 <- (k + seq_len(nr) - 1L) * ncb` (2D) and
`idx <- rep((seq_len(d[[1L]]) - 1L) * plane, each = ...) + base2` (rank-3). `plane`,
`ncb` and the products are R integers; any byte offset past 2^31 - 1 overflows to NA
(with a warning), and raw-vector subsetting by NA yields `00` bytes, not an error. The
result is a structurally valid payload whose tail planes are zeros. Verified live:
`(seq_len(22L) - 1L) * 200000000L` produces 11 NAs; `as.raw(1:10)[NA_integer_]` is `00`.

Exposure: any rank-3 payload where `d1 * d2 * d3 * es > 2^31`, i.e. a 134 MB plane
(4096 x 4096 f64) overflows from plane 17; the f64 store (e452807) halves the f32
threshold. `.sv_trim` runs whenever `.exec_trim`/`.sv_upload` sees a positive trim
(align-style plans, producer pad exceeding consumer need), so the hot fused paths are
safe, but a 20-plus-band f64 cube intermediate on an align plan is inside the corruption
window today. The daemon-side warning is easy to lose.

**Fix sketch.** Do the index arithmetic in doubles (`as.numeric(ncb)` etc.; R indexes raw
vectors by doubles fine), or trim rank-3 payloads plane-by-plane, or reuse the
`.sv_slicer` dim-stamped byte-matrix view (the payload here is private, so the
attribute-write concern that motivated gather-by-index does not apply to a copy).
`.sv_to_matrix`/`.sv_materialise` use `readBin(n = prod(d))` and are fine.

## M2: optimistic `warmed_ck` disarms the cold-kernel defences after a failed warm-up

**Severity: medium.** The defence fails exactly under the memory pressure it exists for.

R/scheduler.R:1350-1358 marks every broadcast kernel warmed as soon as the
`everywhere()` handle is CREATED; `.daemon_warm_jit` swallows failures. For a scan on an
`n_comp <= 2` pool (line 1165 includes scan specs there), a warm-up that dies in the
multi-GB compile (the plausible failure) leaves `warmed_ck[[ck]]` TRUE, and then:

- the slow-start gate (lines 1775-1777) is skipped (`!isTRUE(warmed_ck[[t$ck]])`), and
- `mb_eff` (lines 1652-1655) never charges `scan_compile_mb`,

so up to `cap_comp = 2 * n_comp` scan tasks launch key-only, each misses
(`garry_jit_miss`), and each resends with the closure; every daemon then compiles cold,
concurrently, with no surcharge in `mb_inflight`, while the machine is already tight
enough to have failed the warm-up. On the default 2-daemon pool the concurrency equals
what the broadcast would have attempted, so this is a regression of the accounting
guarantee ("the LIVE budget bounds concurrent cold compiles", 7b2467c) rather than a new
worst case; on an explicit wider pool with a scan the spec is not broadcast, so the wide
case is safe.

**Fix sketch.** Treat the resend as cold: in the `garry_jit_miss` branch (lines
1817-1824), clear `warmed_ck[[tasks[[k]]$ck]]` so subsequent launches of that kernel
re-enter the ramp and the surcharge. Cheap and local; alternatively await `warm_handle`
results before setting `warmed_ck`, at the cost of serialising run start.

## L1: `compute_inflight` cap wrongly throttles fused reads

R/scheduler.R:1656-1658 with 1766. `comp_ok` first rejects on
`n_inflight[["comp"]] >= cap_comp_opt`. Fused READ tasks (`t$mb > 0`) are routed through
`comp_ok` for the byte budget but never count toward `n_inflight[["comp"]]`; when a user
sets `garry.compute_inflight` and the compute tag is at cap, ready fused reads are
blocked for no resource reason. No deadlock (the cap frees on harvest); wall-time only.
Fix: apply the count cap only when `t$pool == "comp"` (e.g. move the check out of
`comp_ok` into the comp branch of the launch scan).

## L2: edge-chunk raw materialisation breaks the 4 B/px store estimate

`.exec_mask_edge` (R/executor.R:277-301) materialises a raw payload to R doubles whenever
an edge chunk has a positive pad, on both the fused-read path
(R/scheduler.R:129-130) and the compute path (292-295). Correct, but the stored region is
then doubles while `.store_bytes_of` booked 4 B for f32 (R/scheduler.R:1043-1054), a 2x
under-account confined to boundary chunks of stages with `out_pad > 0`. The /dev/shm
ground-truth clamp in `refresh_mem_budgets` bounds the drift. Fix if wanted: re-wrap the
masked matrix via `.sv_from_vec` (2D) to keep the payload raw, or book 8 B for padded
exports.

## L3: abort-path ordering unlinks regions under queued writer tasks

`on.exit` handlers run in registration order: `.daemon_shm_clear` (R/scheduler.R:793-795)
precedes `.daemon_write_close` (1421-1424). On a task failure with writes queued, the
regions are unlinked before the writer maps them, so queued `.daemon_write_chunk` tasks
fail after the run has already aborted; nothing harvests them, so the only cost is noise
and a moment of racy mapping (mori mapping of an unlinked name fails cleanly; an
already-mapped region stays valid). The partial output file is documented behaviour.
Fix if wanted: register the write-close/drain handler before the shm-clear handler, or
drain `wr_inflight` with errors tolerated inside an error handler.

## L4: byte-per-pixel constants ignore f64

`.plan_read_px` (R/passes.R:1032-1042), `.stage_fuse_act_bytes_px` (R/passes.R:960-974)
and `move_mb` (R/placement.R:136) hard-code 4 B/px. An f64 source or f64-heavy fused
chain is under-priced 2x in window sizing and in the fuse working-set gate
(`fuse_reader_mb`). These are calibration estimates and the store-residency admission
uses true element sizes (`.store_bytes_of`), so the failure mode is oversized windows and
an optimistic fuse gate, not unbounded memory. Fix: scale by
`.store_bytes_of(dtype, use_raw)` per input node.

## L5: partial pool re-mask on taskset failure

`.pool_affinity_apply` (R/scheduler.R:533-553) returns NULL as soon as one `taskset`
invocation fails, after having re-masked earlier pids; `.comp_pool_shape` (566-576) then
keeps the old `comp_threads`. Masks and state disagree until a later successful re-shape.
Transient `taskset` failure is unlikely; consequence is a mis-costed placement and uneven
masks, not incorrectness. Fix: apply all masks, then report; or revert applied masks on
failure.

---

## Checked and clean

Suspicions from the brief that the code actually handles; recorded so they are not
re-litigated.

- **Writer refcounting (risk 1).** `dispatch_write` increments `store_users[[ref$rk]]`
  before `release_store(k)` runs in the same harvest iteration, and consumer refcounts
  are registered at task-build time, so no interleaving can drop a region before its
  write lands, including a fused sink region serving both a write and downstream compute
  (per-chunk increments on the shared read-task key; each write decrement is matched in
  `harvest_writes`). `flush_drops(force = TRUE)` at drain end only flushes regions whose
  refcount already hit zero; pending writes hold refs. The writer drain
  (R/scheduler.R:1920-1928) completes and awaits `.daemon_write_close` before any output
  is reopened or returned. Live-verified: single-sink fused stream through the writer,
  mixed f32/f64 multi-export through one writer, and combine-partial alongside a fused
  sink all match the oracle (repro2 A-D).
- **Resend accounting (risks 2, 3).** A `garry_jit_miss` resend replaces the handle
  without touching `ck_inflight`, `mb_inflight` (the decrement uses the stored
  `mb_live`), `n_slot` or `n_inflight`; the task completes once and is decremented once.
  A second miss aborts via the `resent` flag. Read-pool tasks cannot raise
  `garry_jit_miss` (their `fuse$fn` always ships), so the `slot == "read"` resend branch
  is dead but harmless.
- **Ramp deadlock (risk 3).** A permanently erroring kernel aborts the run
  (`cli_abort`), and every admission gate (ramp, byte budgets, store gates) opens when
  nothing is in flight, so the `length(inflight) == 0` deadlock check cannot fire
  spuriously; writes are not tasks and cannot strand the loop.
- **f64 write demotion (risk 5).** `gdal_write_window` converts raw payloads through
  `.sv_to_vec` (element size from `gdt`) before `v[is.na(v)] <- nodata`, so NaN demotion
  covers raw f64 and f32 alike; `.exec_write_chunk`'s rank-3 raw path propagates `gdt`
  per plane. `g_download_raw` stamps `gdt` from the device dtype and rejects non-float;
  `.sv_upload` passes `attr(v, "gdt")` through. The one hard-coded `"f32"` upload in
  `.apply_fuse` is guarded by the `raw_in` dtype gate.
- **Fused pricing (risk 4).** `store_mb_read` for a fused read prices the EXPORT's
  planes, dtype and pad (`out_nb`, `out_dtype`, `out_pad`), keyed under `oid = C@id`
  consistently with `task_stage_of`, `stage_store_mb`, `host_keep` and `.exec_in_meta`'s
  `node_stage`. Rank-3 exports price via `.node_outer_nb` correctly.
- **Affinity floor (risk 6).** Every k computation floors at 2 (`garry_daemons`,
  `.pool_affinity_apply` default, `.comp_pool_shape`); `garry_daemons` unconditionally
  rewrites both `.garry_state` entries, including to NULL on teardown, so state does not
  leak across pool generations.
- **In-memory single-chunk fused sink (risk 4).** `nrow(it) == 1` retrieval goes through
  the fused-aware `read_chunk`; element names strip to the export node key
  (`sub("\x1f.*$", ...)`), matching `.key(nid)`.
- **qa_plane.** Traced and oracle paths agree: NaN QA is caught by `g_is_nodata` before
  the `< qa_floor` comparison can produce NA, and the shape check accounts for the extra
  plane.

## Test-coverage note

The new tests (test-fuse-wide.R, test-placement*.R, test-store-residency.R) cover fused
multi-export sinks whose exports are all compute products. None covers a multi-export
containing a raw source next to its derived product (H1), a >2 GiB trimmed payload (M1),
or a failed warm-up (M2). H1's repro below is small and fast enough to become a test
directly.

## Appendix: repro scripts and observed output

Scripts live in the session scratchpad; inline here for reproduction.

**repro1 (H1, cost mode).** 60x40 f32 fixture; `list(raw = x, doubled = lazy_map(x, fn =
function(v) v * 2))`; `garry_daemons(2, 1)`. Observed:
`garry_explain_placement` decides `fuse` (cost) / `comp` with "rules: sink stage keeps
its own tasks" (rules, checking only C); `execute_plan_mirai(p)` returns
`doubled` correct, `raw` NULL, no error; `execute_plan_mirai(p, path = d)` returns
normally, `raw.tif` corner reads 0 (expected 101), `doubled.tif` correct. Task log shows
`s1_r1` launch/done and exactly one write event.

**repro1c (H1, rules mode).** Same plan, `options(garry.placement = "rules")`:
`raw` is NULL in memory (`doubled` correct), confirming the unfused split retrieval hole
independently of fusion.

**repro2 (risk-7 paths, all pass).**
A: single-sink fused chain streamed through the writer daemon: matches oracle.
B: f64 `lazy_map` sink, in-memory (bit-identical) and streamed write: matches.
C: multi-export path=NULL, global-mean combine + fused map sink: matches.
D: mixed f32/f64 multi-export to a directory through one writer: matches.

**overflow demo (M1).** `(seq_len(22L) - 1L) * 200000000L` gives 11 NAs (integer
overflow); `as.raw(1:10)[NA_integer_]` yields `00`: NA indices into raw zero-fill rather
than error. Small-scale `.sv_trim` on f64 (2D) verified correct, confirming the defect is
the index width, not the trim logic.
