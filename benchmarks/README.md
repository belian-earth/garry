# garry benchmarks

The reference workload is vrtility's median-composite benchmark
(`vrtility/benchmarks/`): HLS S30 from Planetary Computer over a PNG
bbox, all of 2023, Fmask bits 0-3 masked, warped to the EPSG:20255
30 m grid, temporal median, written to disk. The aim is parity with
Open Data Cube + dask; vrtility already beats it.

Numbers are network-sensitive: always compare runs from the same
sitting, against a vrtility baseline measured in that sitting.

Two Kalman-smoother scripts ride the ScanNode work
(design/scan-node-design.md): `kalman-kfas-validate.R` diffs
`kalman_llt()` against hutan's per-pixel KFAS smoother on real tile
pixels, and `kalman-smooth-bench.R` times the end-to-end smooth
(hutan KFAS+mirai vs garry scan on CPU / CUDA; f64 GPU throughput is
immaterial, the pipeline is read-bound) and doubles as a live
fidelity check.

Kalman results (2026-07-16, synthetic 15 x 1024 x 1024 stack, robust
LLT mean + sd, 8 compute daemons; CUDA = RTX A1000 4 GB with a
2-daemon pool -- larger pools exhaust the card):

| arm | wall | MPix-yr/s | vs hutan |
|---|---|---|---|
| hutan (KFAS per pixel + mirai) | 282.2 s | 0.06 | 1x |
| garry scan, CPU PJRT | 58.4 s | 0.27 | 4.8x |
| garry scan, CUDA | 36.0 s | 0.44 | 7.8x |

Fidelity garry-vs-hutan: NaN patterns identical, p99 |diff| 8e-6
(mean) / 5e-7 (sd). A handful of pixels per megapixel differ visibly:
hutan's robust loop takes a hard z > 3 threshold, so pixels whose
standardised innovation sits within float noise of 3 flip their
Q_scale between two implementations that agree to 1e-7. Knife-edge
sensitivity of the threshold, not a compute divergence (a
same-precision reference shows max |diff| 7e-5 across 1024 sampled
pixels).

Bilateral context (`bilateral-context-bench.R`, 2026-07-16, 24 bands
x 2048^2, local source, 8 compute daemons vs 20 rayon threads):
kernel-only the XLA bilateral matches rustyfilters (0.061 vs 0.065
s/band); end-to-end (filter + MLP predict) is a wash -- rf arm
(rustyfilters -> materialised context cube -> garry predict) 20.4 s
vs garry "fused" 21.6 s (0.94x), fidelity 3e-6. Two reasons the
fusion doesn't win locally: the materialisation rustyfilters forces
lands in page cache (cheap), and garry's merge pass keeps each
bilateral in its OWN kernel (halo stages stay narrow, passes.R), so
the garry arm runs 6 focal kernels + 1 MLP kernel, not one fused
kernel. The identified unlock is a planner refinement -- allow
small-halo focal stages to fuse into a same-source multi-input
consumer -- at which point the whole context+predict collapses to one
kernel per chunk. On remote sources both arms read the same bytes,
so the standing garry advantages are operational (no intermediate
artifact, one plan, GPU option), not wall-clock.

## Results (2026-07-14, fast link)

garry now runs at parity-to-ahead of ODC + dask on both the median
composite and NDVI, on the CPU, same-sitting interleaved (`compare.sh`
and `compare-ndvi.sh`):

| pipeline | bands | garry | ODC + dask | ratio |
|---|---|---|---|---|
| median composite | 3 (B04/B03/B02) | 15.63 s | 15.72 s | 1.01x |
| NDVI | 2 (B04/B08) | 11.97 s | 12.64 s | 1.06x |

NDVI is best-of-4 and garry won every rep (11.97 / 12.70 / 12.59 /
12.62 s vs ODC 12.64 / 12.74 / 13.10 / 13.02 s); a 2-rep sample had
caught ODC's fastest run and read as a wash, so run >=4 reps. Output
correctness cor 0.996 (composite 0.99); the residual is
nearest-vs-bilinear tile resampling, not a compute difference.

Two structural changes closed the 1.9-2.1x deficit recorded below:

1. **GDAL-direct composite fast path**
   (`.execute_composite_direct` / `.execute_composite_pipeline`): warp
   each slice's f32 pixels straight into a device buffer (no per-chunk
   store round-trip), and run each band's temporal reduce on a compute
   daemon overlapped with the next band's fetch. This handles the pure
   composite.
2. **Reduce-decomposition general path**
   (`.gd_decompose` / `.execute_gd_reduce`): any reduce-structured
   graph (NDVI, nested reduce->map->reduce, focal-over-composite) runs
   by computing its leaf temporal reduces via that same overlapped
   pipeline, then the rest of the graph on the small 2D results in one
   lean kernel. For NDVI the upper `(B08-B04)/(B08+B04)` kernel costs
   0.06 s; ~85% of the wall is the shared network fetch. It is measured
   byte-identical to the whole-grid and scheduler executors
   (`test-gd-general.R`). Before it, NDVI had no fast route and ran
   through the general scheduler at 21-35 s (2-3x behind ODC); it is
   now ahead.

Numbers stay network-sensitive; garry's run-to-run variance is higher
than ODC's (whole-slice warp reads vs ODC's fine-window threaded
reads) but it stays ahead across reps. Tightening read variance is the
remaining frontier, orthogonal to the compute paths.

## Thread-topology spikes (2026-07-29, placement-pass branch)

Evidence for the placement cost pass (`design/placement-cost-pass.md`,
`design/scheduling-review-2026-07-29.md`). 20 logical cores.

**Spike A: CPU affinity bounds the XLA CPU client pool.** Affinity is
applied to freshly spawned mirai daemons with `taskset -a -cp` BEFORE
the first `g_jit` (the client inits lazily), then one trivial kernel is
jitted and `/proc/<pid>/status` read:

| condition | threads/daemon | Cpus_allowed_list | note |
|---|---|---|---|
| uncapped | 93 | 0-19 | baseline (32 pre-anvl + ~61 XLA) |
| k=4 disjoint | 45 | e.g. 0-3 | pool scales with the mask |
| k=2 disjoint | 39 | e.g. 0-1 | stable across 4 and 8 readers |
| k=1 | segfault | - | XLA client dies; k=2 is a HARD floor |

The pool follows `NumSchedulableCPUs` as expected; disjoint sets bound
machine-wide contention regardless of the residual per-process thread
count (the 32-thread baseline is mostly an idle BLAS pool). Reader RSS
after one trivial jit is ~277 MB: the "lean ~60 MB reader" figure does
not survive fusion, and N-reader XLA memory must be priced by the
placement pass. Daemons with a live XLA client segfault at teardown
(`daemons(0)`) after results are returned; this predates the spike
(today's compute pool has the same lifecycle) but is now visible.

**Spike B (micro): MLP-shaped throughput by pool topology.** Kernel
`relu(W1[64x145] %*% x[145x262144]); W2[1x64] %*% h` per 512x512
window, input resident on the daemon, 600 windows dispatched from the
host (dispatch+harvest included, as in the real drain):

| topology | win/s | vs 2 fat |
|---|---|---|
| 2 daemons, uncapped (current compute pool) | 81.4 | 1.00x |
| 6 daemons, k=3 | 109.6 | 1.35x |
| 10 daemons, k=2 | 159.8 | 1.96x |
| 16 daemons, k=2 (oversubscribed: 32 masked CPUs) | worse than 10 | short-run check only |

N narrow XLA clients beat 2 fat ones ~2x on exactly the kernel shape
the SI predict is bottlenecked on, host dispatch included. This is the
data (not a shipped change) for revisiting the fixed 2-daemon compute
pool once the placement pass can price thread width; the real SI-tail
benchmark rerun happens at PR5 validation. Scripts:
`benchmarks/spike_a_affinity.R` / `benchmarks/spike_b_topology.R`.

**SI bench sweep (2026-07-30, bc-cohort box 1, rules vs cost mode,
readers=4 compute=2, MEMMAX=32G).** First real-pipeline validation of
the cost pass (`pipelines/bc-cohort-si-bench.sh placement=`):

| crop | placement | tasks | predict phase | total | note |
|---|---|---|---|---|---|
| 1024 | rules | 426 | 98 s | 371.0 s | completes |
| 1024 | cost | 345 | 80 s | **349.4 s** | AEF predicts FUSED onto readers |
| 2048 | rules | 565 | 531-576 s | - | tail OOM (host anon ~31 GB, pre-existing) |
| 2048 | cost | 565 | ~548 s | - | fusion refused by working-set guard; tail OOM as rules |

Findings the sweep forced into the engine:
- Store-bearing compute launches need their OWN escape hatch: sharing
  read_ok's starved the drain and pinned the 24G scope (fixed).
- The shm backstop must take CGROUP headroom (tmpfs pages charge the
  scope while host df shows free space).
- The ESD arm (the big half: 145 bands x 12 yr) cannot fuse yet: QA
  gating makes its predict stage TWO-input
  (hutan `predict_mlp_lazy(qa_col=)`), failing the single-input
  precondition. Fusing it needs same-file QA-band absorption into the
  coalesced read (planner work, not placement).
- Fused kernels execute at READ granularity: the AEF MLP holds ~2 KB/px
  of activations, fine at a 1 Mpx window (~2.4 GB/reader), fatal at
  4.2 Mpx (~9 GB/reader, three readers OOM-killed). Bounded by
  `garry.fuse_reader_mb`; the long-term fix is fusion-aware read
  window sizing at plan time.
- The crop=2048 tail OOM is `hutan::si_tail` host-side anon (~31 GB,
  deterministic, scales with pixels) — a pipeline scaling wall
  upstream of the engine, present in both modes.

**SI bench, second sweep (2026-07-30, after QA-in-cube + fusion-aware
windows + working-set admission; both arms fuse under cost).**

| crop | placement | predict phase | total | note |
|---|---|---|---|---|
| 1024 | rules | 88 s | 325.6 s | |
| 1024 | cost | **47 s** | **286.2 s** | ESD + AEF fused |
| 2048 | rules | 551 s | 948.6 s | completes (30.9 GB peak / 32G) |
| 2048 | cost | **175 s** | **571.3 s** | predict 3.1x vs rules |
| 0 (full box) | cost | 229 s | 721.8 s | completes; 32.8 GB peak / 42G |

The predict phase — the design doc's target — went 1261 s (pre-layout
fix) -> 551 s (rules) -> **175 s** (cost, fused) at crop=2048. The
residual gap to hutan's 362 s total is the tail phase (Kalman scan +
ensemble on the 2-daemon pool) plus host-side fits/validation — a
different workload from the predict, and the next candidate for the
narrow-pool topology spike B measured. crop=0 needed one more
mechanism: fused reads carry their kernel working set into the
in-flight compute byte budget, or a cold fleet ramps N XLA working
sets on top of the lazy_cog staging (~11 GB tmpfs at crop=0).
`garry.placement` default flipped to "cost" after this sweep.

**Pool-topology levers (2026-07-30, after the flip).** Per-PID tracing
of the crop=2048 tail attributed its memory to three co-resident
parts: the host's streamed-write machinery (oscillating 4-8 GB at
1 Mpx, 15-19 GB at 4.2 Mpx — transient, scales with pixels), each
compute daemon's scan working set (~6.5 GB warmed), and the scan
kernel's cold XLA compile (~10 GB extra on whichever daemon compiles;
one daemon measured 16.5 GB total during compile+first-chunk).
Topology sweep at crop=2048 cost mode, MEMMAX=32G:

| compute pool | outcome |
|---|---|
| 2 (fat masks, scan warm-up pre-drain) | completes, 586.5 s, peak 25.5 GB |
| 10 (narrow masks, lazy compiles) | OOM: every daemon that runs a scan task pays the compile; mirai cannot route to warmed daemons, so width multiplies compiles |

Rules this encoded in the engine (all general, none SI-specific):
- `garry.pool_affinity`: every daemon of BOTH pools gets a disjoint
  CPU slice at creation; any XLA client anywhere is narrow.
- Per-plan pool shaping: scan-bearing plans re-mask the compute pool
  to half-machine slices (scans are long sequential-in-t kernels whose
  plane parallelism narrow masks starve); kernel-fleet plans keep
  narrow disjoint masks. Re-masking is sched_setaffinity, ~ms.
- Cold-kernel slow start + `garry.scan_compile_mb` admission
  surcharge: compiles are staggered AND priced against the live byte
  budget, so any pool width is safe.
- Scan warm-up only on pools of <= 2 daemons (pre-drain, host quiet);
  wider pools compile lazily under admission.
- Default compute pool stays 2: after cost placement fuses kernel
  fleets onto the readers, the pool's residual work (scans, big fused
  reductions) is compile-bound. Width is a safe, explicit choice for
  non-fusable fleets (~2x measured, spike B).

The host streamed-write spike was then fixed the same day: streamed
sink chunks write on a dedicated WRITER daemon (one per session; GTiff
is single-writer), shipped as mori region names and reaped per task.
Measured at crop=2048 cost: 600.2 s (noise band vs 586.5 host-write),
with NO process above 7.7 GB where the host previously oscillated at
15-19 GB — the tail's memory is now structurally bounded instead of
depending on the host spike missing the scan compiles. Host-side
inline writes remain the fallback without the pool. crop=0 still wants
MEMMAX=42G on this box: its extra resident is the ~11 GB lazy_cog
whole-AOI staging (activates only on raw tiled sources), not the write
path. The f64 store followed (design/f64-store.md): raw f64 payloads
ride the store bit-identically to the doubles path (one as_raw memcpy
per hop instead of double conversions on the whole Kalman state path),
with dtype-aware store estimates (f64 regions were booked at half
size). crop=2048 cost: **576.2 s** (best yet vs the 586.5-600.2 band),
tail 363 s, peak 25.6 GB. Remaining: hutan-side point fits/validation
time, and the tail scan compute itself (the CUDA scan measured 7.8x if
the tail ever wants the GPU).

**Deep-review pass validation (2026-07-31, degraded-link sitting).**
After the review roadmap landed (read retry, ABI guard, RSS
correction, task-log schema + report, labels, MPC re-sign, L-fixes):

- Composite A/B best-of-3: garry 47.60 s vs ODC 43.68 s. The WHOLE
  sitting ran ~3x the 2026-07-14 times (link), and gdal-direct's few
  whole-slice reads degrade more than ODC's fine windows on a bad link
  — the documented variance note / io-review R6 case, not the pass.
- SI crop=2048 cost, three same-sitting runs: 622.2 s (correction v1,
  budget floored 602 MB mid-tail), 657.9 s (unmanaged-old fix,
  tightens 1.5-2.3 GB during the scan ramp), 673.6 s (CONTROL,
  `rss_correction = FALSE`). Tails 414 / 411 / 425 s — the correction
  costs nothing measurable (the control was slowest); the +50 s tail
  vs the f64-store baseline (363 s) and the predict drift
  (185/222/225 vs 175 s) are sitting noise on a loaded box + link.
  Peak host RSS 4.9 GB all runs (writer-daemon profile holds), scope
  peak 27.0 GB / 32G.
- First production run of the correction caught it over-tightening on
  RETAINED warmed-scan memory; fixed same day with dask's
  unmanaged-old semantics (run-start baseline + trailing ~30 s
  tolerance; only RECENT growth beyond in-flight work tightens) and an
  off-switch (`garry.rss_correction`).
- `garry_task_report()` on the run: peak modelled 13952 MB vs measured
  fleet anon 14122 MB — the admission model is honest to ~1% at
  crop=2048. The report's stage table isolates the tail scans
  (p95 322-409 s) without ad-hoc parsing for the first time.

**Tail-squeeze experiments (2026-08-01, crop=2048 cost, same box).**
Three probes after the surcharge recalibration
(`scan_compile_mb` 10000 -> 1500, measured from task-log RSS: nv_scan
compiles cost ~0.7-1.0 GB, not the unrolled era's 10 GB):

| arm | predict | tail phase | total | outcome |
|---|---|---|---|---|
| compute=2 CPU (new surcharge) | 185 s | 405 s | 623.7 s | sitting-band parity; surcharge neutral at width 2 |
| compute=4 CPU, MEMMAX=42G | 221 s | - | - | OOM-killed at ~38.5 GB scope |
| compute=1 CUDA (A1000 4 GB) | 696 s | 1054 s | 1774.1 s | completes; card thrashes |
| compute=2 CUDA | - | - | - | RESOURCE_EXHAUSTED (two clients share 4 GB) |

Findings:
- The tail's width wall is the RETAINED per-daemon scan working set
  (~6.5 GB of reusable XLA pool per daemon that has run a scan chunk),
  not compile cost: width 4 = ~26 GB standing state + transients, dead
  at 42G. Compiles are now ~20-25 s / ~1 GB (loop-lowered), so the
  width-1 routing follow-up fixes compile MULTIPLICATION but not this
  wall — wide scan pools need either a smaller per-daemon scan
  footprint or more RAM.
- CUDA on the 4 GB laptop card is a net 2.8x LOSS on the full SI
  workload (the 7.8x Kalman result was a small synthetic stack that
  fit comfortably); shelved until a per-phase device knob can put only
  the tail scans on a bigger card.
- The tail-phase decomposition (task report): ~126 s host-side hutan
  point fits (Kalman hyperparameter MLE at GEDI shots — identical in
  the default hutan engine; cache/parallelise on the hutan ledger) +
  ~288 s garry drain of ~800-900 s compute over 2 daemons.

**Workstream B: scan retention + the width wall (2026-08-01/02).**
`benchmarks/scan-retention-spike.R`: a scan daemon's idle standing
state is mostly reclaimable (475/904 MB glibc arena, 72 MB jit
handles; distinct kernels accumulate ~60-90 MB each, reruns plateau).
Shipped malloc_trim hygiene (src/trim.c, per-task + run-start +
`garry_pool_hygiene()`): idle state 904 -> 557 MB, wall time
unchanged. But width 4 at crop=2048 still died at ~38.9 GB: kill-time
attribution shows 22 GB LIVE fleet (one daemon peaking 11.8 GB in its
cold scan window) vs 1.3 GB modelled — the wall is live scan working
sets rotating across the anonymous pool, not idle retention. The
1500 scan_compile_mb recalibration was reverted (unsafe for the SI
smoother shape); routed dispatch is now the memory-confinement lever,
and MEMMAX on this 62 GB box stays <= 32G (a 42G scope at ceiling
took the desktop session down).

**Cache + width verdicts (2026-08-02, quiet box, MEMMAX=32G).**
Width-2 crop=2048 cost with the A1 smoother cache: cold 649 s (tail
phase 406 s, pays + saves the fit), cached **552.2 s** (tail phase
332 s) — a NEW BEST at this crop (prior 576.2 s), ~74 s of Kalman
MLE + tau_break gone from every warm sweep iteration (the conformal
point fit still runs). Width-4 retry with all three defences active
(restored surcharge, per-task trim, RSS correction): killed again
inside its own 32G scope — width 4 at crop=2048 definitively does not
fit a 62 GB box; scan-memory confinement via routed dispatch
(workstream C) is the required lever, with wide sweeps on the
bc-cohort box.

**Routed dispatch validation (2026-08-02, C1-C3 landed).**
`garry.routed_dispatch = TRUE`, SI crop=2048 cost, compute=6 routed
(scans confined to profiles 1-2, mixed per-role masks), MEMMAX=32G on
the 62 GB box where anonymous width 4 died twice at ~39 GB:
**total 399.8 s, tail phase 148 s, peak scope anon 25.75 GB.** The
tail is 2.2x the cached width-2 best (332 s), the total beats every
recorded crop=2048 number (552.2 cached / 576.2 f64-era / 948.6
pre-placement), and peak memory came in BELOW the width-2 runs —
scan confinement holds scan memory at K=2 working sets while six
narrow profiles carry the map/ensemble fleets. Predict reads are LOCAL
(engine-cmp cache) — its 185-227 s spread across the day's runs was
concurrent box load (test suites) and page-cache state, not network;
on a quiet box (the July-30 175 s predict, same machine) the total
projects to ~350 s, under hutan's 362 s for the first time.

**Routed width/K sweep (2026-08-02, same box, quiet).** crop=2048:
c6/c8/c10 at K=2 = 399.8 / 401.2 / 412.5 s (tails 148/149/149 s,
peaks 25.8/27.1/27.5 GB) — width saturates at 6; the tail is bounded
by K=2 scan throughput + host point work, and c10 (July's anonymous
OOM width) just works routed. c8 K=3 and crop=0 die contained at 32G
(K=3 costs the ~6 GB it says; crop=0 keeps its 42G-class need).
Sweet spot here: compute=6, scan_profiles=2. Details in
design/routed-dispatch.md.

**Raw-BSQ cube format (2026-08-02).** Predict-phase read
investigation: GDAL's tile walk costs ~2.2 s per 482 MB 73-band window
REGARDLESS of codec (ZSTD == uncompressed == VRT-raw through the GDAL
path) vs 0.24 s raw — so garry gained a raw cube format (.bin +
sibling VRTRawRasterBand .vrt; reads bypass the tile walk incl.
partial-width windows via byte-index subsetting; .vrt sinks write
through the existing paths incl. the writer daemon;
stage_raw_cube() converts, carrying band descriptions). Pipeline A/B
(2 years, routed c6): predict 54 -> 49 s (-9%), read-task median
5 -> 3.9 s. The bounded win is the honest headline: the predict phase
is ~75% fused MLP COMPUTE, ~25% IO — the next predict lever is reader
width (build_si hard-codes 8), not formats. Suite green incl.
byte-identical fast-vs-GDAL equivalence gates (test-raw-cube.R).

**Scheduler-route composite A/B (same sitting, composite_direct=FALSE,
3 reps interleaved)**: baseline f72cbce 40.24/41.84/38.48 s vs
placement-pass 42.99/40.98/42.58 s. Ranges overlap; a branch run with
`read_affinity = "off"` lands at 42.32 s, so the ~2 s mean drift is
not the affinity cap. Within this benchmark's documented run-to-run
variance; re-run interleaved on a quiet link if the 5% matters. The
default composite route (gdal-direct) bypasses the scheduler and ran
38.46 s in the same sitting.

## Historical results (phases 9-11)

2026-07-08 ~00:30, ODC baseline added (same-sitting triple; cgroup
v2 `memory.peak` for the whole scope, which counts shared pages
once). The ODC run does MORE compute (morphological mask cleanup)
and is the historical best-in-class:

| pipeline | bands | wall time | cgroup peak | transferred |
|---|---|---|---|---|
| vrtility main (15 daemons) | 3 | 33.2 s | 6.9 GB | - |
| ODC + dask (20-thread pool) | 3 | 35.6 s | 4.3 GB | 648 MB |
| garry, mori store (12 daemons) | 3 | 41.9 s | 10.4 GB | 649 MB |

Transfer volume is identical to ODC and the read drain is at the
link ceiling under every config measured (chunk-size, GTI threads,
daemon count, HTTP version: all dead levers — see
design/phase10-odc-gaps.md). garry's remaining gap is its
network-idle serial segments (host build ~3.5 s, last band's compute
tail ~4.5 s, write) and its memory footprint (12 R+XLA processes vs
one 20-thread process). The gap analysis and prioritised plan live
in design/phase10-odc-gaps.md.

Earlier that night, reduce-join fusion boundary + mori store
(interleaved trio):

| pipeline | bands | wall time | cgroup peak |
|---|---|---|---|
| vrtility main (15 daemons) | 3 | 33.4 s | 6.9 GB |
| garry, mori store (12 daemons) | 3 | 42.2 s | 10.0 GB |
| garry, rds store (12 daemons) | 3 | 42.9 s | 8.5 GB |

Earlier the same night under a better network window the ratio
touched parity: vrtility 34.9 / 36.6 s vs garry (rds, reduce-join
boundary) 36.0 s. WiFi drift across the night moved vrtility between
33.4-39.7 s and garry between 36.0-54.3 s; interleave runs and
compare ratios within a trio only. Correctness held at cor 0.992
(mad 13.9) vs the vrtility B04 composite throughout.

What changed tonight, in order of effect:

1. Declared-grid sources (see "What the 2.1x actually was"): the
   graph-build metadata storm is gone; host build+plan is ~3.5 s.
2. Fusion never crosses a reduction into a join: each band's
   mask -> stack -> median fuses to one stage, but medians stay
   materialised below the band stack. Each band's compute tail then
   starts as soon as ITS reads land, overlapping the next band's
   drain (task log: B04 computes ran 12.9-18.6 s into a 27.6 s
   drain). Only the last band's ~4.5 s tail is serial. Cost: three
   store round-trips of the already-reduced composites (~28 MB).
3. `options(garry.store = "mori")`: chunk store in POSIX shared
   memory (mori package). Reads share their windows once; consumers
   extract their pre-split part element zero-copy; nothing touches
   disk (the rds store round-trips ~2 GB per run through tempdir()).
   Read regions release as soon as every consuming stage finishes.
   Wall time is within run noise of rds tonight (the drain is
   network-bound either way); the win is no disk churn and no
   tempdir dependency, at ~1.5 GB of shm while stages are in flight.

2026-07-07 evening, stage-merge pass + decoupled reads: vrtility
31.0 s, garry 65.4 s (6.9 GB). Earlier same day, before the
stage-merge pass (slower network hour): vrtility 37.9 s, garry
merged-plan-only 73.5 s. 2026-07-05, faster connection: ODC + dask
28.4 s, vrtility 20.7 s, garry per-band collects 131.7 s.

## What the 2.1x actually was (2026-07-07 night)

The phase 9b session scope hypothesised the 2.1x gap lived in the
read path (H1 GTI driver overhead, H2 transfer volume, H3 HTTP
config). Measurement refuted all three:

- H1: a slice window read via GTI vs per-item warped VRTs of the
  underlying COGs is 0.9 s vs 1.5 s per slice; GTI is FASTER (and
  per-item reads fetch overlap regions twice).
- H2: identical transfer (~643 MB) across GTI/per-item and both HTTP
  configs, at matching wall times.
- H3: the benchmark's 220-read fleet workload runs in 32 s under
  garry's env, vrtility's env, and garry-minus-HTTP/2, identically.
  Single-stream throughput to MPC is ~5 MB/s; 8 parallel streams
  reach ~27 MB/s; 12 daemons aggregate ~20 MB/s. The drain is at the
  link ceiling; daemon count (12 vs 16) and config move nothing.

The actual gap was on the host, before any read: each of the 220
`lazy_source()` calls opened its GTI slice mosaic to discover
metadata, and the GTI driver satisfies that by opening one remote COG
per open (~0.1 s x 220, serial). Another ~3.6 s went to
`stac_gti_index()`: PROJ re-selects coordinate operations per bbox in
`transform_bounds()` (~7 ms x 98 rows x 4 assets) and per-feature
GPKG writes. Fixes, in garry:

1. `lazy_source(grid =, block_dim =)` declares the source's grid and
   skips discovery; the STAC layer probes metadata once per asset
   (4 opens instead of 220) since every slice of an index shares it.
2. `stac_gti_index()` transforms only unique footprints (HLS items
   sit on 2 MGRS squares, so 98 transforms collapse to 2) and writes
   FlatGeobuf instead of GPKG. 3.6 s -> 0.1 s.
3. `options(garry.task_log = <path>)` makes the scheduler log
   per-task launch/done timestamps; the decomposition above came from
   it and it stays for future profiling.

Chunk-count experiments (6 x 512 px vs 12/20 smaller chunks) showed
the fused tail is dominated by per-chunk fixed costs (220 store-file
reads + uploads per chunk, plus per-daemon XLA compile), so fewer,
larger chunks win; `chunk_target_px = 1.4e6` stands.

What the fused architecture changed: the planner's stage-merge pass
folds single-consumer compute chains into their consumers, so
mask -> stack -> median -> band stack runs as ONE XLA program per
chunk (172 members, zero intermediate store round-trips); the chunk
store is uncompressed (gzip cost hundreds of ms per chunk for
nothing); and read granularity is decoupled from compute granularity
(sources read whole windows once, split into per-compute-chunk store
files on write, so the compute tail parallelises and overlaps the
read drain without re-opening mosaics). Offline (local files) the
identical workload dropped 59.9 s -> 14-19 s.

Correctness: garry's B04 vs vrtility's agrees at correlation 0.992
(mean abs diff ~14 reflectance units; nearest-vs-bilinear tile
resampling and per-day-slice vs per-item stacking).

Remaining levers: trim the ~2.4 s of graph build + planner passes
(S7 `@` and `%in%` dominate the profile), and the last band's
compute tail (its XLA compile could in principle warm during the
drain, but mirai cannot route tasks to specific daemons, so a warm
task would displace a read for as long as it compiles - a net loss;
measured reasoning in the phase 9b notes). Both are second-order
next to the read drain, which is bandwidth-bound.

A mori-store lesson worth keeping: consumer-side RANGE subsetting of
a mapped shared matrix materialises the whole window per input (R's
subscript path, not a memcpy) - on the benchmark that was multiple
GB of transient daemon heap and a ~2x cgroup peak. Element
extraction from a shared list is the zero-copy path, which is why
reads share their windows pre-split.

## Memory postmortem (2026-07-07)

The first merged-plan runs OOM'd a 62 GB machine. Root cause: stage
closures captured the whole 500-node graph (directly, and via user
mask-fn environments that referenced LazyRasters and through them the
graph again). One mask-stage closure serialized at ~117 MB; every
mirai task shipped one and every daemon retained a deserialized copy
per stage in its jit cache. Fixes, all in garry:

1. `.compose_stage_fn` extracts per-member specs and never captures
   the graph; user fns are rebound onto minimal environments holding
   only their free variables (`.slim_fn`, codetools). Stage closures
   are now ~300 KB.
2. The GDAL dataset handle cache is LRU-capped
   (`garry.handle_cache_max`, default 4) and closes evicted handles:
   open GTI warping mosaics pin warper + VSICURL + block-cache memory.
3. The benchmark exports `GDAL_CACHEMAX=256`: GDAL's block cache
   defaults to 5% of RAM PER PROCESS and every daemon inherits it.

With all three, the full three-band run peaks at 8 GB fleet-wide.

## Running

```sh
Rscript benchmarks/hls-median-composite.R 12 B04           # one band
Rscript benchmarks/hls-median-composite.R 12 B04 B03 B02   # full workload
Rscript benchmarks/ndvi-garry.R auto                       # NDVI (general path)

REPS=4 benchmarks/compare.sh        # composite: garry vs ODC, back to back
REPS=4 benchmarks/compare-ndvi.sh   # NDVI: garry vs ODC, back to back
```

`compare.sh` / `compare-ndvi.sh` interleave garry and ODC runs, report
every rep and the best-of, and diff the two output GeoTIFFs so a speed
win can't hide a wrong answer. The ODC baselines
(`hls-median-composite-odc.py`, `ndvi-odc.py`) need the venv in
`benchmarks/.venv/`.

Network required (Planetary Computer, anonymous + pre-signed hrefs).
The STAC query is untimed, matching the reference benchmarks. The
scheduler prints task progress (`options(garry.progress = TRUE)` is
set in the script); a three-band run is ~226 tasks (220 whole-window
GTI reads + the fused compute chunks).

Note on the vrtility baseline: `vrtility/benchmarks/benchmark_r_vrtility.R`
names a `vrtility_median` GDAL pixel function that is not registered by
any installed component (daemons fail with "read raster failed"; the
underlying GDAL error is "pixel function not registered"). The 37.9 s
baseline above was run from vrtility main with GDAL's built-in `median`
pixel function instead, host and daemons running the same installed
build.

## What the script shows about the API

- `stac_query()` -> `stac_sources()`: search results become a flat
  table (one row per item x asset); `stac_drop_duplicates()` /
  `stac_time_slices()` are plain-R table operations.
- `stac_gti_index()`: the table becomes a GDAL GTI tile index; each
  day is a `FILTER`ed mosaic of that index, pinned to the target grid
  via open options (mixed UTM zones are reprojected per tile by GDAL).
- `lazy_map(band, fmask, dtype = "f32", fn = ...)`: elementwise ops
  written in plain R with the `g_*` vocabulary; they trace into fused
  XLA kernels.
- `lazy_stack() |> reduce_over("median", "t", nan_rm = TRUE)`: the
  per-band composite; NaN is nodata everywhere (D8).
- `lazy_stack(composites, along = "band")` + one `collect(path =,
  distributed = TRUE)`: all bands in ONE plan -> one multiband GTiff.
  One scheduler queue keeps the network saturated across bands, and
  graph merge dedups the shared Fmask sources (read once, not per
  band).
