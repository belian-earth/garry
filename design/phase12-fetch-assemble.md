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
