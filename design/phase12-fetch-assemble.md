# Phase 12: split fetch from assembly

The read path's problem, measured (phase 11 re-baseline + probes,
2026-07-08): a remote GTI warped read is 74% network wait — the
GTiff reader fetches ranges sequentially through the warper, so a
reader's connection idles between block round-trips and the fleet
never saturates the link (fast link: ~20 MB/s of 60+ available;
best tuned wall 33.2 s vs ODC 17.4 s). GDAL offers no in-RasterIO
range parallelism on this stack (GDAL_NUM_THREADS regressed both
the GTI and direct-COG paths). The warp itself is cheap: the same
mosaic read is 0.14 s against local copies. GTI is exonerated
(0.11 s opens); per-item warped VRTs win nothing (9b holds in both
regimes).

## Design

Split the read stage's one blocking unit (fetch+warp of a whole
slice mosaic) into two task kinds:

1. **Fetch** — one task per item-asset: `gdal_translate -srcwin` of
   exactly the AOI-intersecting window (plus a warp-kernel margin),
   remote COG -> small local GTiff on tmpfs (/dev/shm), native
   dtype, native-block aligned. The remote path is a plain windowed
   COG copy: no warp, no mosaic, no abstraction between the bytes
   and the disk. Tasks are small (~3 MB payload, ~0.3 s), UNIFORM
   (a cold object stalls one fetch, not a slice), and numerous
   (392 for the benchmark) — many blocking reads in flight is the
   only concurrency GDAL allows, so make the blocking unit tiny.
2. **Assemble** — per (slice x asset): today's GTI mosaic, pinned
   to the target grid, over the LOCAL window files (locations
   rewritten in the index); warped read at local speed (0.14 s
   measured), split producer-side into store parts exactly as
   today. GTI keeps its roles (mosaic order, culling, mixed-CRS
   pinning) as internal structure over streamed assets.

Everything above the read boundary — store, pools, byte budget,
content-addressed kernels, XLA compute, streaming writes — is
untouched.

## Why this serves both network regimes

The fetch fleet's binding constraint becomes the link itself:
~650 MB at 60 MB/s is ~11 s of drain (vs 35 s+ today). On a slow
link the same bytes move with at-least-equal parallelism, so the
current bandwidth-bound parity is preserved — the regime
auto-tuning problem largely dissolves instead of needing solving.
Readers get thinner (native-dtype windows, no warper state).

## Lifecycle

Local window files are the shm-store pattern on tmpfs: refcounted
by consuming assemble tasks, deleted eagerly when their slice is
assembled, bounding the cache to the in-flight working set
(fetched-not-yet-assembled). Worst case one full workload of
windows ~650 MB compressed.

## Spike gates (before implementation)

- Value parity: assembled-from-local warped read must equal the
  remote GTI warped read exactly (same source pixels, same warp;
  srcwin must carry a kernel margin so bilinear edges match).
- Transfer parity: /proc/net/dev RX delta for fetch-based vs
  remote-GTI reads of the same slices within ~1.2x (block-aligned
  srcwin should touch the same blocks).
- Saturation: 12-20 parallel fetchers hold a large fraction of the
  link (the whole point).
- Composition: fetch-wall + assemble-wall for n slices beats the
  remote read path for the same slices.

## Spike results (2026-07-08, fast link): ALL GATES PASS

- Value parity: 8/8 slices BIT-IDENTICAL to the remote GTI path
  (srcwin margin of 8 px covers the bilinear kernel).
- Transfer parity: 1.02x RX bytes (/proc/net/dev) for the same
  slices.
- Composition: fetch 1.5 s + assemble 1.3 s = 2.8 s vs 6.4 s for
  the remote path over the same 8 slices; assemble costs
  0.17 s/slice sequential.
- SATURATION: the full benchmark workload — 392 item-asset windows,
  616 MB — fetched in 12.2 s at a SUSTAINED 50.3 MB/s with 16
  workers (today's drain: ~35 s at ~20 MB/s for the same bytes).
  Per-fetch med 0.36 s, p90 0.75 s, max 1.62 s: the whole-slice
  path's 12 s p90 tail is gone. tmpfs working set 414 MB
  compressed, 392/392 fetches ok.

Projected benchmark wall: ~12 s saturated drain + overlapped
assembly/compute + tail ≈ high-teens seconds — ODC territory — at
byte parity, so no slow-link regression.

## Implementation status (2026-07-08): SHIPPED, read path solved

Implemented in the distributed scheduler: `gti_index_create()` writes
an entries sidecar; `prepare_fetch()` turns a remote GTI source
stage into per-item fetch tasks (`.daemon_fetch_window` /
`gdal_fetch_window`: srcwin translate to tmpfs, uncompressed — the
DEFLATE re-encode measured as wasted fleet CPU) plus a
location-rewritten local index the unchanged read task assembles
from; fetch failure under read_fail="nodata" writes a nodata
placeholder window so a vanished object degrades to a hole;
per-stage tmpfs refcounting unlinks windows when their slice's last
assemble completes. `garry.fetch` = auto/direct/force ("force"
enables offline tests over local fixtures). Gates in
test-fetch-assemble.R: fetch-backed == direct results, auto skips
local sources, failure degrades, cache cleans up.

Measured (same sitting, fast link, morphology benchmark):
- At matched pools (12+3) fetch wins clearly: 41.3 s / 6.8 GB vs
  52-61 s / 7.0 GB direct.
- At 24 readers the READ PATH IS SOLVED: all 392 fetches done by
  t=18, all 220 assembles by t=20 (direct drain was ~35 s), long
  tail gone.
- BUT the wall stalls at ~37.6 s (24+3 and 20+8 alike; 20+8 costs
  13 GB) because the bottleneck moved: the last ~16 s is the
  COMPUTE side — 330 morphology mask chunks + 18 medians whose
  ~133 s of task time is dominated by per-chunk fixed costs
  (upload, dispatch, store, share) and CPU-bound XLA on a 20-core
  box. ODC bracket: 15.9 s.

Saturation follow-up (user field observation, verified): the first
implementation interleaved assembles onto the readers — every ~1 s
local assemble idled a connection, and the fleet averaged
~18-38 MB/s instead of the spike's 50+. Fix: task PRIORITY in the
ready-queue scan (fetch tasks are prio 1) — the read pool downloads
flat-out while any fetch is pending, then takes assembles. Measured
in-benchmark: 616 MB in 14.3 s = 43 MB/s pure fetch phase. (Routing
assembles to the compute pool instead was tried and REJECTED: it
starved the compute side and left 16 readers idle for 28 s.)

The wall is now pinned at ~38-40 s regardless of pool shape (16+6,
16+10, 24+3 all equivalent; memory grows with pool size, 9-13 GB):
the binding constraint is per-task COMPUTE overhead — 456
assemble/mask/median tasks each paying extract + upload + dispatch
+ store + share around ~0.2 s of actual XLA. ODC's 15.9 s does the
same math with ~zero per-task overhead (numpy in worker threads
over shared task-graph memory). Static pool arithmetic says the
ceiling is ~16-20 s (total CPU ~200 core-s over the box) — reaching
it is 12b, not a config knob.

## 12b results (2026-07-08, same sitting, all interleaved with ODC)

SHIPPED, three pieces, each measured on the morphology benchmark
(16+6 pools, ODC brackets 16.5-16.7 s):
1. COMPUTE-ON-READ: single-consumer source-fed compute stages
   (guards: compute kind, cpu device, non-sink, one input stage,
   sole consumer of the source, single export) execute inside the
   source's read tasks — the kernel runs once per coarse window,
   outputs split producer-side. Enabled by a PLANNER rule with its
   own justification: a node bringing new external inputs into a
   focal-bearing stage no longer fuses into it (halo stages stay
   narrow; band sources had been inheriting the mask chain's halo-7
   read windows). Weighted (differentiable) kernels exempt — the v1
   gradient tape needs the single-stage pipeline. Mask tasks
   330 -> 0; chunk tasks 236 -> 16. Wall 37.6 -> 32.2 s.
2. PROFILE SPILL: pools are routing labels — comp-tagged tasks
   prefer the compute pool but take idle read-pool slots once all
   read-tagged work is done (never for non-cpu devices). Assembles
   (comp-tagged) overlap the drain on the computers, then the
   median tail runs on the whole fleet. With the byte-estimate fix
   below: 32.2 -> 28.6 s. (Static routing of assembles to either
   pool alone measured 32-46 s — both idle half the box.)
3. Byte-estimate fix: assemble estimates used the UNCLIPPED coarse
   chunk dim (~700 MB/task -> budget allowed 4 concurrent); clipped
   to the grid it is ~27 MB, and the budget stopped strangling the
   pipeline.

Day's arc on this link (morphology benchmark, garry vs ODC ~16.5 s):
direct reads 60.7 s -> fetch/assemble 41.3 -> +priority 39.8 ->
+compute-on-read 32.2 -> +spill 28.6 s at 10.5 GB. Remaining gap
(1.7x): the 16-median tail (~8 s: 110 store extracts + upload +
55-layer XLA median each) and the ~15 s fetch floor at ~43 MB/s.
Next candidates: small-task batching (below), assemble-side median
pre-stack, fetch coalescing per COG.

Phase 12b (the compute-overhead levers) — CPU ONLY by decision:
GPU wins are real but garry must not depend on them; smash the CPU
bottlenecks first, reach for the GPU after.
1. Compute-on-read: a single-consumer compute stage fed by exactly
   one source stage executes inside the source's read task — the
   kernel runs ONCE on the whole padded coarse window (one XLA call
   per slice instead of six chunk tasks), outputs split
   producer-side like any read. Deletes the 330 mask tasks, their
   dispatch/extract/share overhead, and the raw-Fmask store traffic
   outright; the compute pool's queue drops to the medians. Guards:
   compute kind, not the sink, one input stage, source consumed by
   nothing else, single export.
2. Batch small tasks: one mirai task per (stage, chunk-group) for
   sub-100 ms kernels, amortising dispatch + jit lookup + share —
   only if a bottleneck survives lever 1.
(deferred: device="auto" GPU placement.)

## Implementation sketch (post-spike)

Planner: source stages over remote GTI indices gain a fetch
sub-stage — per item-asset tasks keyed into the scheduler's read
pool; assemble tasks depend on their slice's fetches and run on the
read pool too (they are IO-shaped, 0.14 s). The GTI index for
assembly is the same table with locations rewritten to tmpfs paths.
Fail-soft (garry.read_fail) applies per fetch. The existing
read-granularity decoupling (coarse windows, producer-side split,
halo riding on the window) applies to the ASSEMBLE read unchanged.
Option-gated (garry.fetch = "auto"|"local"|"direct"): local files
and already-local sources skip the fetch stage entirely.
