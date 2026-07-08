# Phase 11 roadmap: closing the ODC gap for good

State after phases 10/10b (same-sitting, 2026-07-08): wall 36.8 s vs
ODC 35.6 s (but ODC runs morphological mask cleanup garry doesn't
yet), fleet peak 7.0 GB vs 4.3 GB, transfer identical at the link
ceiling. What remains is structural: the process model, the last-band
tail, workload parity, and an idle GPU. This is the tick-list; each
item carries its rationale, expected size, and gate. Order is the
recommended sequence.

- [ ] **11.1 Split daemon pools: readers and computers, with a
  memory-budgeted balancer.** mirai compute profiles
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

- [ ] **11.2 Morphology parity benchmark.** ODC's baseline does
  opening(2) + dilation(3) on the cloud mask; garry's doesn't, so
  today's wall comparison undersells ODC. The mask is a MapNode over
  the Fmask SOURCE, so chained focal min/max (erosion then dilation)
  lives in a source-fed stage — D11 already permits it and
  .compose_stage_fn already sequences pad consumption for chained
  focals. Write focal min/max kernels, add the cleanup to the garry
  benchmark, re-baseline all three pipelines same-sitting.
  Expect: garry wall grows (more compute per chunk); the comparison
  becomes honest. Gate: cor vs ODC output on the cleaned mask path,
  interleaved wall/peak triple.

- [ ] **11.3 Streaming sink writes.** Sink chunks currently write
  after the whole drain; write each as it lands (band k's chunks
  complete during band k+1's drain, so all but the last band's
  writes hide entirely). Small (<1 s) but nearly free.
  Gate: write-roundtrip tests unchanged; task_log shows writes
  interleaved with the drain.

- [ ] **11.4 f32 store values.** Store parts are R doubles (8 B/px)
  for data that is f32 on disk and device. Sharing raw f32 buffers
  through mori and uploading straight from them halves shm
  (~1.3 -> 0.65 GB), halves upload conversion, halves per-chunk R
  heap churn. Needs an anvl upload-from-raw entry point (upstream
  candidate, alongside the unsigned-dtype carrier).
  Gate: bit-identical outputs (f32 end-to-end is exact); peak drop
  in the benchmark profile.

- [ ] **11.5 GPU fused stages.** Planner device selection
  (device = "cuda" for compute stages when a CUDA PJRT plugin is
  present); natural on top of 11.1 — the compute pool owns the GPU,
  readers never touch it, pool size 1-2 bounds GPU memory. The
  sort-based nan_rm median (and 11.2's morphology) is exactly GPU
  shaped; PCIe traffic per chunk is ~110 MB in / 3 MB out.
  Expect: tail exec collapses; matters more as compute grows.
  Gate: CUDA daemon equivalence tests (exist), interleaved wall.

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
