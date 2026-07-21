# Reviewer: executor/kernel path (executor.R, ops.R, collect.R, plan.R)

## Priority-1 answer: kernel caching is CORRECT and not the bottleneck
`.daemon_run_compute_shm` caches the jitted closure in `.daemon_cache` keyed by content-addressed `.stage_kernel_sig` (scheduler.R:199-206, 287-329); anvl's shape-keyed cache in JitFunction handles ≤4 chunk shapes (D4). Verified experimentally (730-stage, 5-year × 145-band predict-shaped plan): the 22 year-stages collapse to ONE signature even when the custom MLP closure is built by separate factory calls with identical weights. At bc scale: ~1 sig × ≤4 shapes × n_daemons compiles, warm-up covers modal shape. Custom Reduce/ScanNode fns in the sig (305-318) — no collision. Miss cost ~0.9 s XLA compile (cold 1.45 s vs warm 0.61 s tail chunk). Tracing NOT the predict bottleneck. The cost is what ships alongside:

## Findings (ranked)

- **[performance] [high] scheduler.R:906-917** — Full stage closure fn serialized + shipped with EVERY compute task though daemons ignore it after first jit. Measured: serialize(s@fn) = 3.36 MB for the 145-input predict-shaped stage (9.1 ms/serialize); at ~2-4k compute tasks = 20-60 s single-threaded host serialization + 7-22 GB transport, pure redundancy — .daemon_warm_jit (1000-1008) already broadcasts every distinct fn once at run start. Fused read tasks ship fs the same way (783-786). Fix: fn = NULL for cache keys covered by warm broadcast (daemon error → host resends). Largest single per-task host cost in the drain loop.

- **[performance] [high] scheduler.R:779-787, 824-835** — Every read task ships a ChunkGrid serializing at 333 KB because S7 objects carry full class definitions (S7_class attr 310 KB, nested GridSpec 202 KB; actual payload ~1 KB). At 17-21k read tasks: ~6.6 GB host serialization (~13-14 s) + daemon unserialize per task. Fix: plain-list window spec, or broadcast per-stage grids once via everywhere and ship (stage_id, core_row). ~300x launch-cost drop; exactly where the 16 tasks/s ceiling lives.

- **[performance] [high] passes.R:170-176 (.compose_stage_fn)** — Custom reduce/scan bodies EXEMPT from .slim_fn → entire factory call frame serializes inside every stage fn. Synthetic: closure with 2 MB unused factory-frame data = 1.98 MB raw vs 0.07 MB slimmed (just weights). The stated reason (namespace resolution on daemons) is OBSOLETE: .slim_fn now reparents onto terminal namespace (passes.R:126-135, recent fix). Fix: slim custom fns too. Cannot verify real mlp_project frame contents (hutan external); hazard is structural.

- **[performance] [med] passes.R:168-177** — Stage-fn specs capture whole S7 node objects: ~0.9-1.4 MB pure S7 class/grid metadata per stage closure even after slimming (one spec's node = 2.43 MB). Fix: extract only fields .eval_node needs (class tag, fn, radius/weights/boundary, op/over/nan_rm, pdims) into plain lists at compose time. Combined with the two above: compute payload 3.36 MB → ~2 KB/task.

- **[performance] [med] scheduler.R:264-266 (.daemon_warm_jit)** — warm-up dummy builds one full-chunk zero matrix PER INPUT: 145 × ~8 MB doubles (~1.2 GB) + 145 device uploads (~0.6 GB) held simultaneously per daemon; ×8 daemons warming concurrently = >10 GB transient spike at run start (OOM/swap hazard during read drain). Fix: one dummy per distinct dtype, same AnvlArray for every input of that dtype.

- **[performance] [med] scheduler.R:69-70, 199-200** — jit cache "eviction" wipes ENTIRE cache (rm(list=ls())) at >64 entries incl. the hot wide-stage kernel; re-entry re-jits ~0.9 s+. Predict likely under 64 keys (content addressing collapses per-year dups — verified), but year-distinct captured values in fused chains would thrash. Fix: LRU. Conditional.

- **[correctness] [med] scheduler.R:620-625 vs executor.R:469-474** — scheduler's warp_only drops the reference's `!any(plan@sinks %in% s@members)` guard: multi-export plan with a source node that is a sink but otherwise consumed only by warp stages → execute_plan reads it, execute_plan_mirai skips the read → sink retrieval (1315-1321) finds no chunk_vals entries, fails or mismatches. Edge case but real oracle divergence.

- **[correctness] [verified equivalent — no defect] scheduler.R:617-619, 763; executor.R:264-277, 288-306** — node_stage/consumers_of index args EXACTLY match old Find/Filter: reverse-iteration overwrite = first-wins (partial beats combine for reduce root, matching Find over creation order); consumers_of ascending stage-id so .exec_split_cg cons[[1L]] picks same first consumer; identical() verified on 145-input stage incl. fallback path. Note: .exec_split_cg asserts divisibility only vs first consumer's chunk_dim, safe under plan-wide single chunk_dim.

- **[correctness] [low] scheduler.R:207-209 / executor.R:109-137** — daemon trim path lacks executor's stopifnot(extra >= 0L) (executor.R:538); .sv_trim on raw payload with negative/oversized trim silently reads OOB raw bytes as 00 (verified: raw OOB subsetting zero-fills) → corrupt f32 planes instead of error. Matrix path errors naturally. Planner invariants currently prevent it; add assert in .sv_upload for loud failure.

- **[performance] [low-med] executor.R:469-474, 570-571** — execute_plan retains O(stages²) warp_only Filter (measured 1.74 s @ 730 stages, ~16 s extrapolated @ 2.2k) + O(sinks×stages) sink lookups. Reference path only, but makes cohort-scale oracle comparisons painful; reuse the verified-equivalent one-pass indexes.

- **[performance] [low-med] scheduler.R:87-89, 231-233** — unconditional gc(FALSE) per fused read and per compute task on daemons: justified for ~0.5 GB composite chunks; for predict's small chunks (~10-50 ms kernels) a 5-20 ms gc/task = 10-50% overhead × 20k tasks. Fix: gc only when allocated-since-last-gc exceeds threshold; MALLOC_TRIM env stays as backstop.

- **[performance] [low] scheduler.R:888-896** — in_keys/trims/dtypes recomputed inside per-chunk local() though invariant per stage (~5 vapplys over 145 inputs/task + it[jj,] row extraction 32 µs/row). Hoist per stage, pre-split it into row list. ~1-2 s build time.

- **[simplification] [low] scheduler.R:325-329** — .stage_kernel_sig via tempfile + tools::md5sum; rlang::hash() (already a dep) hashes in memory, removes double serialize.

- **[performance] [low] executor.R:541-543** — per-chunk shapes accounting (145 dim() calls + paste + unique) runs even when garry.exec_stats FALSE; gate on option.

- **[ops.R — no significant defect]** .g_traced dispatch is trace-time only (once per sig×shape compile, never per chunk). Poor-complexity untraced fallbacks (.g_reduce via apply, g_median via stats::median, g_broadcast_arrays copies) are oracle-only. One per-chunk copy of note: .exec_write_chunk rank-3 raw band slicing (executor.R:369-374) allocates 8 B/element index vector per band plane — low.

- **[architecture] [med — cross-ref scheduler]** streamed sink writes synchronous inside harvest loop (1229-1245) + no early break in pooled launch scan when both pools saturated (1172-1206): fixing the payload findings without these moves the ceiling, not removes it.

**Could not evidence:** real mlp_project frame contents; whether real plan exceeds 64 jit keys/daemon; production sink count (sink_task_j lookups measured cheap, hypothesis dropped).

Experiment scripts: scratchpad exp1.R, exp2.R (predict-shaped 5-year × 145-band plan against working tree).
