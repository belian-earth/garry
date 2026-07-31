# Reviewer: scheduler.R (execute_plan_mirai)

## Quantified host cost model

Traced from scheduler.R:1168-1271: each drain iteration does (a) launch scan over EVERY remaining pending task (no early exit in pooled mode), (b) unresolved() sweep over in-flight handles, (c) throttled flush/progress. Measured: full launch sweep at 20k pending = 16.8 ms; mirai::unresolved() = 0.37 µs/handle (~44 in flight = 16 µs/sweep, negligible); gc(FALSE) with 20k task table = 26 ms; ls() on 20k-entry env = 39 ms; mirai() launch serialization ~0.6 ms/MB of captured closure. The polling loop over handles is NOT the scaling problem; the O(pending) launch scan, redundant per-daemon decompression, and host-serialized sink writes are. Promises/call_mirai/dispatcher would not change the ceiling.

## Findings (ranked)

- **[architecture] [high] scheduler.R:1168-1206** — Launch sweep is O(remaining-pending) per iteration, no early exit, ~O(n²) over the run. Only `break` (1177) gated on `!pooled` but `pooled <- TRUE` unconditionally (473); comment at 1164-1166 claiming O(frontier) is FALSE — first_pending only trims the prefix. 16.8 ms/sweep at 20k pending; with Sys.sleep(0.002) the loop spins, pinning a host core. Fix: (1) push tasks onto a ready structure when dep_left hits 0 (reverse index at 1145-1151 exists), dense-integer bucket + min-cursor ordered by task_order rank; (2) skip launch scan on iterations that harvested nothing — slots/budgets/dep_left only change at harvest (verified all mutations). Impact: ~17 ms/iter → µs.

- **[architecture] [high] scheduler.R:1082-1097 + build 697-931** — Window-major only dedups strip decompression WITHIN one reader; 145 same-window band tasks scatter across ~16 read daemons → each daemon decompresses full 72-band strips for its share, ~16x amplification best case. Fits run 5's signature (healthy CPU, far too slow: daemons busy on redundant inflate). Fix: coalesce read tasks sharing (file, window) into ONE task producing per-band elements of one shared region — the parts/source_elts mechanism (803-841, .daemon_run_source_shm parts path 125-135) already supports one region with many named elements; build loop needs grouping key (resolved file path + chunk row) + per-band skeys. Impact: ÷145 task/region count for ESD arm, amplification → ~1x. SINGLE HIGHEST-LEVERAGE CHANGE.

- **[correctness] [high] scheduler.R:409,428-434** — `read_handles = 1L` default likely defeats the block-cache mitigation: each per-band task addresses a distinct per-band VRT; handle-cache depth 1 closes the previous dataset (and VRT source refs) after every task, discarding GDAL block cache → consecutive band reads of same window re-inflate everything even on one daemon. CHECKABLE HYPOTHESIS: rerun cohort with read_handles = 8-16; if wall time moves, confirmed. Zero code change. Possibly the direct cause of run 5.

- **[performance] [med] scheduler.R:905-918, 779-787** — Every compute launch re-serializes the full stage closure fn (incl. MLP weights); 0.66 ms/MB/launch host-side. Daemons already cache jitted kernel under content key ck (executor 199-206; warmup 1000-1008 ships each unique fn once) so per-task fn only needed on miss. Fix: broadcast unique closures once per pool keyed by ck (extend .daemon_warm_jit to store raw fn); resend-on-miss path. Size the win first: length(serialize(s@fn, NULL)) for predict stages.

- **[architecture] [med] scheduler.R:1229-1245** — Streamed sink chunks written by HOST thread inside harvest loop (.exec_write_chunk → GDAL write, executor.R:357-369), serializing I/O with orchestration; no launches/harvests during a compressed write. Fix: dedicated writer daemon (region name is already the wire format), or instrument task_log "write" lines first to quantify.

- **[correctness] [med] scheduler.R:744-753 + 1181-1191 + 1203** — Fetch-backed assemble tasks retagged pool="comp" (753) yet pin store_mb into mb_read_resident at launch (1203); read_ok gate only consulted for pool=="read" (1182-1184): assembles never budget-gated → remote fetch-heavy plan can blow past read_budget_mb, and inflated mb_read_resident throttles genuine reads into serial trickle. Latent (bc-cohort local sources bypass prepare_fetch). Fix: gate comp tasks with store_mb > 0 through read_ok.

- **[correctness] [med] scheduler.R:952 vs 963-978** — Budget decrements at queue time but physical free waits for ≤5 s clock flush + daemon queue latency + host gc munmap; under tight budget shm high-water can exceed budget by everything launched in one flush window (16 readers × ~90 MB = several GB). Fix: also force-flush when sum(store_mb of pending_drop) > ~25% of budget.

- **[correctness] [med] scheduler.R:947-951** — host_keep regions skip queue_drop BEFORE the mb_read_resident decrement → kept read regions permanently consume read budget; plans with many combines/in-memory multi-export sinks strangle read_ok late in run. Fix: account kept total in budget floor (1080) or track separately for diagnosability. Low impact on streamed bc run; real on in-memory collects.

- **[architecture] [med] adversarial check of handoff §3.1** — Region-per-task-output is defensible GIVEN per-(band,window) lifetime; the excess is task granularity, not store design. Per-stage preallocated buffers would WORSEN residency (buffer lives until last window's consumer retires = whole band pinned per stage). Recommend read-task coalescing instead, against the handoff's per-stage-buffer idea.

- **[performance] [low-med] scheduler.R:973** — flush_drops does intersect(pending_drop, ls(chunk_vals)) per flush; ls() = 39 ms at 20k entries, chunk_vals grows with host_keep entries. Replace with per-key exists() filter, O(pending_drop).

- **[performance] [low] scheduler.R:325-329 + fuse loop 672-687** — .stage_kernel_sig hashes via tempfile + tools::md5sum; fuse loop calls it per single-input compute stage → ~2.2k tempfile write/hash/unlink cycles during build (part of 50 s entry-to-launch). Hash in memory (nanonext::sha1, already in dep closure). Seconds off build.

- **[simplification] [med] scheduler.R:473-476, 1174-1177, 1181** — pooled is constant TRUE (garry_daemons_set requires both pools, 467-470); the !pooled branch, if (pooled) wrapper, read_prof/comp_prof indirection are dead. Delete; de-branches the hottest loop.

- **[simplification] [low] scheduler.R:855-862** — duplicated comment block; delete one.
- **[simplification] [low] scheduler.R:1264-1268** — progress uses cat, violating cli rule; cli_progress_* gives rate/ETA free.

- **[correctness] NEGATIVE FINDINGS (verified sound)** — duplicate deps collapsed by unique() (899/923) consistent with dep_left init (1148); multi-consumer refcounts total decrements from release_store (983-990); drop-once marker (task_stage_of[[rk]] <- NULL, 951) prevents double-decrement; chunk_vals entries can't drop before pending consumer launches (consumer holds store_users until retire; launch-time in_vals at 913 safe); first_pending monotone-safe (states never return to pending); streamed multi-export two-sinks-one-stage writes once, drops once. No retry machinery exists → no retry-refcount hazard (worth a comment).

- **[tests] [low]** — test-read-budget.R covers shrinking/eager-release/below-one-set, but not: compute backpressure with budget pinned by host_keep, fetch-assemble bypass, drop/flush ordering under small flush interval. queue_drop/flush_drops/read_ok are plain closures over envs — extractable for deterministic fake-clock unit tests without daemons.

**Top 3 by leverage:** (1) coalesce per-band reads into per-(file,window) tasks via parts store path — ÷145 tasks/regions/amplification; (2) event-gated ready-queue launches — kills O(n²) scan; (3) read_handles experiment (one line) — potentially the direct cause of run 5.
