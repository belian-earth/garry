# Phase 11 roadmap: closing the ODC gap for good

State after phases 10/10b (same-sitting, 2026-07-08): wall 36.8 s vs
ODC 35.6 s (but ODC runs morphological mask cleanup garry doesn't
yet), fleet peak 7.0 GB vs 4.3 GB, transfer identical at the link
ceiling. What remains is structural: the process model, the last-band
tail, workload parity, and an idle GPU. This is the tick-list; each
item carries its rationale, expected size, and gate. Order is the
recommended sequence.

- [x] **11.1 Split daemon pools: readers and computers, with a
  memory-budgeted balancer.** DONE 2026-07-08. `garry_daemons(read,
  compute)` creates garry_read/garry_compute mirai profiles; the
  scheduler auto-detects them, routes read/warp vs compute tasks,
  throttles compute in-flight during the drain
  (garry_opt("compute_inflight"), default half the pool) and opens
  the full pool for the tail; `.daemon_warm_jit` pre-compiles each
  compute stage's modal shape on the pool at run start (cold 1.45 s
  -> warmed 0.61 s per chunk). Read daemons never load PJRT.
  Same-sitting: 12+3 pooled = 6.42 GB peak / 36.5 s (best wall AND
  best peak; single-pool malloc baseline 7.03 GB / 36.8 s; morning
  baseline 9.3-9.8 GB). Gated by test-mirai-pools.R (pooled ==
  single-threaded, anvl-free readers, warm cache, fallback).
  Spike findings that shaped it: everywhere() assignments do NOT
  persist as daemon globals (ephemeral env — warm state must live in
  garry:::.daemon_cache); reader RSS is 58 MB base but grows ~150 MB
  over the drain (curl/TLS/PROJ churn, NOT the GDAL block cache and
  NOT open handles — read_handles=1 saved only ~15 MB); active
  compute daemons hold 1.1-1.4 GB DURING a real chunk (upload
  coercion + XLA sort scratch across the thread pool), bigger than
  the 0.3 GB offline sim. FOLLOW-ONS: attribute the reader drain
  plateau (~150 MB x n_read is now the biggest block); PJRT CPU
  client thread-pool sizing on compute daemons (anvl upstream
  candidate) to cut sort scratch; both fold into 11.4's remit. mirai compute profiles
  (`daemons(n, .compute = "read")`) give task routing to pools.
  Read daemons never touch anvl/PJRT (~40-60 MB base vs ~108 MB);
  compute daemons are few and fat, confining the 0.3-1 GB per-chunk
  working sets to 2-3 processes. OVER-ALLOCATE both pools (idle
  daemons cost base RSS only, zero CPU) and let the host scheduler
  throttle per-pool in-flight dynamically. The balancing currency is
  BYTES, not cores: cores rebalance themselves (idle readers use no
  CPU, the OS hands the tail to compute threads for free), but each
  in-flight compute chunk holds ~0.3-1 GB, so the compute cap is
  budget-driven: inflight_compute x per-chunk estimate <= ram_budget
  minus the live read/shm footprint. The scheduler already refcounts
  read regions (read_users), so the freed budget is known as the
  drain winds down and the compute cap RISES as reads retire — the
  read side's memory funds the tail's parallelism, holding peak flat
  instead of stacking tail spikes on the drain plateau.
  Also unlocked by pools: jit pre-compilation via
  `everywhere(.compute = "compute")` during the host's STAC/index
  phase (the old warm-up rejection was about displacing reads; a
  dedicated pool has nothing to displace) — removes the ~0.9 s
  first-execution compile from tail chunks.
  Spike first: profile routing semantics, two-pool dispatcher
  behavior, everywhere() per profile, idle-daemon RSS.
  Expect: peak ~4-4.5 GB (ODC territory) at wall parity or better.
  Gate: interleaved benchmark trio, peak and wall.

- [x] **11.2 Morphology parity benchmark.** DONE 2026-07-08 except
  the wall re-baseline (below). The benchmark now applies odc-algo's
  mask_cleanup — opening(2) then dilation(3), disk structuring
  elements — as chained focal min/max (erosion = product over the
  disk on a 0/1 f32 mask, dilation = its dual) in a Fmask-source-fed
  halo-7 stage, computed once per slice on a SHARED graph (cross-
  graph import only dedups sources, so per-band graphs would have
  tripled the morphology). NaN (fill + beyond-edge halo) maps to
  clear, matching scipy's constant-0 border; fill pixels are -9999
  in band data anyway. Offline gate: exact match to a pure-R
  morphology reference; pooled == single-threaded. Correctness gate
  vs ODC PASSED: cor 0.987-0.991 per band over 1.17M px against
  ODC's cleaned composite (historical 0.992 band-level agreement).
  Three scheduler/planner improvements fell out of making it fast:
  (a) CONTENT-ADDRESSED KERNEL KEYS — .stage_kernel_sig normalizes
  node ids to stage-local indices and hashes member structure +
  serialized slimmed fns, so 55 structurally identical per-slice
  mask stages compile ONE kernel per daemon instead of 55 (the
  first morph run was 96.9 s from that compile storm alone), task
  bodies rename exports positionally, and kernels persist across
  runs; (b) BYTE-BUDGET COMPUTE BALANCER — per-task resident
  estimates (.stage_bytes_per_px x chunk px: mask chunk ~10 MB,
  fused median ~350 MB) gated against ram_budget x pool size,
  replacing the flat drain-phase cap that had serialized 330 tiny
  mask tasks two-at-a-time; (c) COARSE READS WITH HALO — halo'd
  source stages now read coarse and split producer-side like
  halo-free ones (a compute chunk's padded window is contained in
  the coarse window padded by the same halo), keeping 55 Fmask
  sources at 55 reads instead of 330.
  REMAINING: same-sitting wall/peak triple in a clean network
  window. Tonight's link collapsed mid-session (ODC 34.8 -> 56.4 s
  across two hours; garry no-morph 36.5 -> 86.7 s; interleaved
  ratios degraded for everyone and more readers made it worse) —
  no wall conclusion is honest from that data. Morphology's
  incremental cost on the degraded link was ~12 s (98.3 vs 86.7
  same-sitting).

- [x] **11.3 Streaming sink writes.** DONE 2026-07-08. The output
  dataset opens at run start and each sink chunk writes in the
  harvest loop (task_log gains "write" events); the post-drain
  batch write is gone. Gated by streamed-vs-single write equivalence
  (multiband + 2D) in test-mirai-pools.R.

- [ ] **11.4 f32 store values.** BLOCKED on anvl (upstream ask
  below); garry-side follow-ons folded in from 11.1's profiling:
  the reader drain plateau (~150 MB/daemon native growth —
  curl/TLS/PROJ churn, not block cache, not handles) and compute
  daemons' 1.1-1.4 GB during-chunk anon (upload double-coercion +
  XLA sort scratch across the PJRT thread pool).
  Store parts are R doubles (8 B/px) for data that is f32 on disk
  and device. Sharing raw f32 buffers through mori and uploading
  straight from them halves shm (~1.3 -> 0.65 GB), halves upload
  conversion, halves per-chunk R heap churn.
  UPSTREAM ASK (r-xla/anvl), precise: (1) `nv_array()` accepting a
  raw vector (or ALTREP-backed buffer) + explicit dtype + dim,
  uploading WITHOUT the R-double round-trip — today doubles are the
  only numeric carrier, which is also why unsigned dtypes need the
  widening carrier in garry's g_upload; (2) a client option to size
  the PJRT CPU thread pool (compute daemons currently inherit
  hardware_concurrency each; 3 daemons x 16 threads oversubscribes
  and multiplies sort scratch).
  Gate: bit-identical outputs (f32 end-to-end is exact); peak drop
  in the benchmark profile.

- [x] **11.5 GPU fused stages.** DONE 2026-07-08 (wall measurement
  deferred to the clean-window re-baseline with 11.2).
  `options(garry.device = "cuda")` (or GARRY_DEVICE=cuda for the
  benchmark): the planner stamps compute/reduce_partial stages with
  the device; both executors jit and upload on it (reads,
  host-side combines, and source/warp stages stay CPU); kernel
  cache keys include the device. Gates: CUDA plan equivalence vs
  CPU (pooled, both stores) in test-mirai-cuda.R, green on the
  RTX A1000; the full 3-band morphology benchmark ran end-to-end
  on CUDA (12 readers + 2 GPU computers).

## Clean-window re-baseline (2026-07-08, fast link, interleaved)

All runs same sitting, morphology ON for ODC and garry (equal work),
cgroup peaks. The link offered 60+ MB/s (ODC brackets improved
through the sitting: 21.7 -> 17.2 s).

| run | wall | peak |
|---|---|---|
| ODC + dask (20 threads) | 21.7 / 17.2 s | 4.36 / 4.27 GB |
| garry CPU 12r+3c | 60.7 / 52.0 s | 7.02 GB |
| garry CPU 20r+6c | 33.2 s | 11.05 GB |
| garry GPU 20r+2c | 39.3 s | 8.2 GB |

THE REGIME FLIPPED. On the old ~23 MB/s link garry was
bandwidth-bound and within 1.05x of ODC; on a fast link garry is
PER-READ-FIXED-COST bound: each of the 220 coarse reads moves ~3 MB
of payload (~50 ms at link speed) but takes ~1.9 s of service time —
GTI per-slice open (FGB + per-tile COG header round-trips), warper
init, decompress. 12 reader slots x overhead-dominated reads ≈
20 MB/s regardless of the pipe; the task log shows the drain ends at
t=35 and the network sits idle through a ~13 s median tail on 3
computers. More slots help linearly but cost memory (20r+6c: -19 s,
+4 GB) and oversubscribe the 20-core box. Whole-GPU placement was
NET SLOWER than 6 CPU computers (39.3 vs 33.2): 330 tiny mask chunks
pay PCIe + dispatch per task on 2 daemons — device placement should
be per-stage by task size (medians yes, masks no), not global.

Phase 12 levers, in expected order of value:
1. Cut per-read fixed cost: per-item sources with daemon-held handle
   reuse (9b rejected per-item WARPED VRTs on a slow link — overlap
   fetch amplification; on a fast link the calculus reverses and the
   9b measurement should be REDONE), or a GTI open-cost diet
   (pre-fetched headers, shared FGB handle, warper reuse across
   slices differing only in FILTER).
2. In-daemon read concurrency: a reader that overlaps k opens/
   transfers (async GDAL or multi-dataset interleave) multiplies
   slots without multiplying processes — attacks the same ceiling
   as "more readers" at ~zero memory cost.
3. Per-stage device policy: garry.device = "auto" placing stages on
   GPU only above a task-byte threshold.
4. Reader footprint diet (fold of 11.4): ~250 MB/reader at peak is
   what makes slot count expensive.

## Measured dead — do not re-litigate

Upload batching (0.08 s of a ~2 s chunk); finer chunks (fixed costs
beat tail parallelism, 10.8 -> 18.5 s offline); GDAL_CACHEMAX trim
and VSI_CACHE=FALSE (block cache never fills, VSI already off);
MALLOC_ARENA_MAX (mmap threshold already bypasses arenas); fewer
homogeneous daemons (8 daemons: peak 6.7 GB but drain 40 -> 48 s);
jit warm-up DURING the drain (displaces reads — superseded by
11.1's pre-drain pool warm-up).

## End state

If 11.1-11.5 land: memory at ODC parity, wall at-or-better on equal
work, GPU gear ODC's config doesn't have, and the remaining
difference is R+mirai process bases (~1 GB) — the acceptable price
of the daemon model until a v2 shared-process backend is worth it.
