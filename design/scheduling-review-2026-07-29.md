# Scheduling and architecture review, 2026-07-29

Status: review complete. Companion to `placement-cost-pass.md`, which this
review amends; the amendments and the implementation order are recorded
there. Written after a full read of `R/scheduler.R`, the planner passes,
the executor/read path, the design history, and hutan's parallel predict
path.

## Verdict

The staged-dataflow chassis is fit for purpose; its resource model is not.
The chassis (lazy IR to stage plan to host-orchestrated task drain over
split mirai pools with a mori shared-memory store) reached ODC parity on
the composite (1.01x) and NDVI (1.06x) benchmarks and wins the Kalman arm
4.8-7.8x against KFAS. Every cohort-scale failure, including the four
consecutive scaling defects behind the 2026-07-20 deep review, the 556 s
vs hutan 362 s predict gap, and the crop=0 /dev/shm flood, traces to one
of three missing resource-management capabilities, not to the chassis.
Nothing here requires a rewrite. The host drain loop is measured not
poll-bound (0.37 us/handle, review-2026-07-20/scheduler.md), and the
placement-cost-pass proposal is the correct consolidation of the policy
layer, with the amendments below.

## Capability 1: thread topology is unmanaged

This is the root cause the placement design does not name. Every XLA
client sizes an eigen thread pool to all cores (~63 threads per client on
a 20-core box, `scheduler.R:462-478`). Four scheduler rules are downstream
symptoms of that single fact:

- the compute daemon ceiling of 2 (`scheduler.R:478`);
- the thread cliff that ruled out more daemons (2 to 4: slower and +14 GB;
  8 OOMs);
- the strict no-spill rule (`scheduler.R:1289-1292`, commit f72cbce);
- the multi-band fusion exclusion (`scheduler.R:762`).

Two facts sharpen this from observation to defect:

1. Fused read tasks already violate the lean-reader invariant.
   `.apply_fuse` (`scheduler.R:68-90`) calls `g_jit` on the read daemon,
   so any fused plan loads anvl/PJRT there; the "reader stays at ~60 MB"
   claim (`scheduler.R:409-411`) has been stale since phase 12b. The read
   pool defaults to logical cores, so a fused plan can instantiate one
   all-cores XLA client per logical core. Mask cleanup tolerates this
   because its kernels barely use the pool; a fused 145-band MLP would
   not. Fusing the MLP onto ~20 uncapped readers builds a larger thread
   cliff than the one the 2-daemon pool avoids.
2. hutan's winning topology is thread-capped, not fat.
   `hutan/R/predict-parallel.R:118` sets `torch_set_num_threads(1L)`:
   N single-threaded owner-computes workers over disjoint row bands. The
   fusion route only reproduces that topology if each reader's XLA pool
   is capped.

Thread width must therefore become a scheduled resource: the placement
pass prices it, and the engine gains a mechanism to bound per-daemon XLA
pools. The zero-patch lever is CPU affinity: XLA sizes its pool via
`tsl::port::MaxParallelism()`, which respects `sched_setaffinity`, and the
client initialises lazily on first `g_jit`, so affinity applied at pool
creation bounds the pool. The clean cross-platform answer is a thread
count option on the anvl/PJRT CPU client; that upstream ask already exists
(`phase11-roadmap.md:118-120`) and pjrt's `plugin.cpp` already forwards
arbitrary named int64 create options.

The same lever reopens the compute-pool question itself: the measured
ceiling is really "2 x 63-thread clients", and N narrower clients may
dominate (hutan is the existence proof). This round only measures that
configuration (spike B in the amended plan); no topology change ships.

## Capability 2: placement policy is scattered and shape-keyed

The placement-cost-pass thesis is confirmed: five decision sites, each a
structural predicate encoding one benchmark's lesson, with `scheduler.R:762`
the emblematic line. Three amendments to the design as written:

- The pass must run at execute time. Pool widths, available RAM, and
  fetch-backedness are runtime facts; a `plan_lazy`-time pass would bake
  stale resources into a reusable Plan. The seam is the top of
  `execute_plan_mirai`, after `warp_only` is built; the result is a side
  table, not a Stage property, so the oracle and gdal-direct routes never
  see it.
- Thread demand joins memory, FLOPs, and movement as a cost term, per
  capability 1. FLOPs are derivable today with no IR change: custom
  reducer closures are deliberately not slimmed (`passes.R:172-175`), so
  the MLP's layer matrices are introspectable from
  `environment(node@fn[[1]])$weights`.
- Decisions must be inspectable. A public explain surface printing
  decision, both modelled costs, and the reason per chain is part of the
  deliverable, or placement regressions become archaeology.

## Capability 3: shared-memory residency accounting is partial

The floods are the sum of untracked terms, not a mystery:

- Compute outputs are refcounted for release but carry `store_mb = 0`
  (`scheduler.R:995`), so the admission gate never sees their bytes.
- The fetch cache (`garry-fetch-<run_id>`) and gdal-direct `.bin` cubes
  (`gdirect-<pid>`) are unbudgeted tmpfs; only lazy_cog's staging is
  sized against RAM. `gdirect` keys on PID alone, so concurrent collects
  in one session collide.
- Edge chunks materialise raw payloads to doubles (`.exec_mask_edge`),
  costing 8 B/px against a 4 B/px booking.
- `mb_read_resident` decrements at queue-drop time while the physical
  unlink lags on the flush clock (`scheduler.R:1053-1090`); high-water can
  exceed budget by everything launched inside one flush window.

One latent defect found that interacts directly with the placement work:
for a fused stage, `store_mb_read` (`scheduler.R:846-850`) is priced from
the source window including every band, but the stored region is the
kernel output. A fused 145-band MLP read would be over-charged roughly
145x and the read budget would serialise the fleet, silently destroying
the fusion win the cost pass exists to capture. The residency fix must
land before the placement default flips.

The fix set: account compute-output bytes in the gated quantity; clamp
the budget against actual `/dev/shm` free space as a backstop and force
a flush when headroom is breached; price fused regions from the export
grid; and trace the crop=0 run with `garry.task_log` before changing any
policy, per the design doc's own instruction.

## Secondary debts (schedule separately, do not bundle)

- Host critical path: streaming sink writes and reduce_combine run on the
  dispatch thread; ~333 KB of S7 `ChunkGrid` serialization per read task
  (99% class definitions); the launch sweep is O(pending) per harvest.
  At the measured ~16 tasks/s drain ceiling, granularity is bounded by
  host throughput; the catalogued items (writes off the host thread,
  event-driven readiness, slimmer task payloads) are worth one targeted
  pass after placement lands.
- Two divergent executors plus the unreachable `.execute_gd_general`;
  multi-export collect is barred from both fast paths
  (`collect.R:51-71`). The placement pass is built as an execute-time
  annotation over the one Plan IR partly so it converges rather than
  forks the executors further.
- Band coalescing is a planner rewrite that silently no-ops off the
  bare-SourceNode shape; per-band sources remain an IR-level debt.
- No retry machinery for cloud reads; `read_fail = "nodata"` is the only
  net.
- Dead code: `fusable()` / `is_barrier()` generics and `FusedNode` are
  unused by the planner.
- `garry_daemons()` docstring still says compute defaults to physical
  cores; the code sets 2.

## Measured-dead ideas (do not re-litigate)

More fat compute daemons; profile spill; the Icechunk-style manifest;
finer chunks; upload batching; global CUDA placement; GDAL cache tuning
(`phase11-roadmap.md:217-225`, `phase10-odc-gaps.md:22-26`,
`placement-cost-pass.md:189-199`). A dispatcher or non-R rewrite is not
justified by the evidence: the ceilings are policy and granularity, and
both are addressable in place.
