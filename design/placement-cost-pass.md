# Cost-based placement pass: dissolving the hand-coded fusion rules

Status: **implemented through PR4 on branch `placement-pass`
(2026-07-29); default remains `garry.placement = "rules"` pending PR5
benchmark validation.** Amended after the scheduling review
(`scheduling-review-2026-07-29.md`). Self-contained.

Landed: residency fixes (compute-output store bytes, cgroup-aware
/dev/shm backstop, fused-region pricing, a dedicated escape hatch for
store-bearing compute), the placement pass with rules and cost modes
plus `garry_explain_placement()`, `.stage_flops_per_px` and
`.stage_fuse_act_bytes_px` with MLP closure introspection, reader CPU
affinity (`garry.read_affinity`), FUSED SINK streaming (chunk_of /
sink_task_map), the fat-pool efficiency term (spike B calibrated), and
the fused window working-set bound (`garry.fuse_reader_mb`). Also
fixed en route: a phase 12b defect where a fused multi-export sink
wrote all-zero output.

First real-pipeline validation (SI bench, 2026-07-30): at crop=1024
cost mode fuses the AEF predicts (426 -> 345 tasks) for predict 98 ->
80 s and total 371 -> 349.4 s, oracle-identical. Two structural limits
found: (1) the ESD arm cannot fuse — QA gating makes its predict stage
two-input; fusing the big half of the workload needs same-file QA-band
absorption into the coalesced read (planner work); (2) fused kernels
run at read granularity, so wide-hidden MLPs exceed per-reader memory
on large windows — bounded for now, properly fixed by fusion-aware
read window sizing at plan time. PR5 default flip remains gated on the
full benchmark set; the crop=2048+ tail is blocked by a pre-existing
hutan::si_tail host-memory wall, not by the engine.

## Amendments from the 2026-07-29 review

1. **Thread topology is a fourth cost dimension.** `.apply_fuse` runs
   `g_jit` on the read daemon, so fusion already makes readers XLA
   clients, each sizing an all-cores eigen pool. Fusing the 145-band MLP
   onto N uncapped readers would oversubscribe worse than the 2-daemon
   model it escapes. hutan's winning topology is N x 1-thread workers
   (`predict-parallel.R:118`). The pass therefore prices per-daemon
   thread width, and the engine gains a reader thread cap via CPU
   affinity applied at pool creation (XLA sizes its pool through
   `tsl::port::MaxParallelism()`, which respects `sched_setaffinity`;
   the client inits lazily on first `g_jit`). Without a cap, wide
   kernels never fuse (a FLOPs/px gate preserves today's behaviour).
2. **The pass runs at execute time, not plan time.** Pool widths and
   available RAM are runtime facts. The seam is the top of
   `execute_plan_mirai` after `warp_only`; the output is a side table
   consumed by the task build, not a Stage property, so the oracle and
   gdal-direct routes are untouched.
3. **A latent store_mb defect must be fixed before the flip.** For a
   fused stage `store_mb_read` (`scheduler.R:846-850`) is priced from
   the source window (all bands), but the stored region is the kernel
   output; a fused 145-band read would be over-charged ~145x and the
   budget would serialise the read fleet, cancelling the fusion win.
4. **Step D grows two items**: compute outputs join the gated resident
   bytes (they currently carry `store_mb = 0`), and the budget is
   clamped against actual `/dev/shm` free space with a forced flush on
   headroom breach.
5. **Implementation order**: PR0 review docs + affinity spike (+ a
   data-only measurement of N narrow compute daemons vs 2 fat on the SI
   tail); PR1 residency fixes (this is the crop=0 enabler and a
   prerequisite for valid cost calibration); PR2 extract placement in
   rules mode, zero behaviour change; PR3 cost model + explain behind
   `garry.placement = "rules"`; PR4 reader affinity; PR5 default flip
   gated on the validation targets below. The fetch-backed assemble
   reroute (site B, `scheduler.R:832`) stays in the scheduler for v1: it
   depends on `prepare_fetch`'s stateful probing and is orthogonal to
   fuse-vs-materialise.

## Thesis

garry decides *where* each operation runs (fuse into the read task vs route to
the compute pool) with hand-written structural predicates, one per situation.
The proposal is to replace those predicates with a single cost-based placement
pass over the plan, so the engine optimises the execution pathway from the
computation actually requested rather than from a lookup table of node shapes.
The immediate payoff is the multi-band MLP predict, which the current rules
force onto the 2-daemon compute pool and which a cost model would instead fuse
onto the N read daemons, matching hutan's saturating read+compute topology.

This is surgical, not a rewrite. The engine already holds the two hardest
pieces of a cost-based optimiser: a per-op cost function and a resource-aware
admission controller. Two hand rules stand in the way, and one hard constraint
must be respected rather than removed.

## Motivating measurement (this session)

The SI predict bottleneck was the ESD cache byte layout (1-row-strip
pixel-interleave, ~12 MB/s reads). Rewriting the cache to tiled band-interleave
gave 61x read in isolation and dropped the box-1 crop=2048 predict from 1261s
to 556s. hutan on the same box is 362s.

The residual 556 vs 362 gap is no longer reads. It is the compute model: garry
runs the MLP on 2 fat XLA daemons; hutan runs 18 lightweight workers that each
read and compute their own window. The full-extent (crop=0) run then flooded
/dev/shm because reads outran the 2-daemon drain: proof the read wall is gone
and the limits are now compute placement and back-pressure.

Both remaining limits are outputs of the same missing mechanism: a
resource-aware placement pass. Fusion is the pass choosing to pipeline instead
of materialise; back-pressure is the pass bounding reads in flight against the
memory budget. This is why the general design is simpler than two point fixes,
not more complex.

## The five placement-decision sites (as they stand)

| # | Decision | Location | Nature |
|---|---|---|---|
| A | Fuse compute into read? | `R/scheduler.R:750-771` | Structural predicate |
| B | Read pool vs compute pool | `R/scheduler.R:819, 832, 784` | Assigned by node kind/origin |
| C | Compute daemon count | `R/scheduler.R:478` | Hard constant `2L` |
| D | Residency / byte budgets | `R/scheduler.R:1224-1246, 1305-1314` | RAM split + admission gates |
| E | Per-op cost function | `R/passes.R:861-889` | Exists; memory-only |

### A. The fusion rule (the rule to dissolve)

`R/scheduler.R:750-771` builds `fuse_of` / `fused_cid`, deciding whether a
compute stage runs on its read task. The gate is a chain of structural
predicates:

- `C@device == "cpu"` (752): GPU compute never fuses.
- `length(C@inputs) == 1 && length(C@exports) == 1` (753): single-in/out only.
- single consumer of the source (756).
- `if (length(graph_get(graph, S@members[[1L]])@band) > 1L) next` (762):
  **the multi-band exclusion.**

Line 762 is what keeps the 145-band MLP off the read node. Its comment states
the assumption directly: fusing a wide kernel "would move the plan's whole
compute onto the lean read daemons and idle the warm pool." That is correct
for plans where compute should stay on the warm pool, and exactly backwards for
the MLP-predict case where we want compute spread across the N read daemons. A
cost model re-decides this per plan. The single line a general pass replaces:
`if band>1 next` becomes `if cost(materialise) < cost(fuse) then do not fuse`.

### B. Pool assignment

`R/scheduler.R:819` defaults every read to the `"read"` pool; `832` reroutes
fetch-backed (remote) assembles to `"comp"` because that pool idles during the
drain; `784` makes fused stages run on their read task. Placement is by node
kind and data origin, never by cost. Strict no-spill is enforced at
`1289-1292`: a compute task never lands on a read daemon (it would spin up a
full XLA client there). Fold B into A's decision so "which pool" is an output
of the cost comparison, not a kind-based branch.

### C. The compute-daemon ceiling (constraint, not a rule to remove)

`R/scheduler.R:478`: `compute <- 2L`, justified by measurement (`462-477`):
each daemon is a full XLA client with a ~63-thread CPU pool on a 20-core box,
so a third oversubscribes; "measured 2->4: slower AND +14 GB peak; 8 OOMs."

A cost model does not lift this ceiling. It is an architectural bound the pass
must read and respect. It is also *why* fusing the MLP wins: fusion is the only
route to running compute on more than 2 workers, by placing it on the N read
daemons. A and C are coupled: the multi-band exclusion at 762 exists because of
the 2-daemon model, and the way past both is to let the cost model choose
fusion when it beats the 2-pool route.

### D. Back-pressure (mechanism exists, mis-parameterised)

`R/scheduler.R:1305-1314` is the admission controller:

- `read_ok`: admit a read only if `mb_read_resident + store_mb <= read_budget_mb`
  (escape hatch: nothing in flight, so a single over-budget read still makes
  progress one at a time).
- `comp_ok`: admit compute under a count cap and
  `mb_inflight + t$mb <= comp_budget_mb`.

`refresh_mem_budgets` (`1224-1246`) sets both from live RAM: `pool = avail *
mem_frac`; reads get at most `pool/3`, compute the rest. This *is* the shm
back-pressure. The crop=0 flood was not a missing mechanism; it was this gate
admitting too much, because the resident-bytes estimate (`store_mb`, built at
`846-850`) or the pool/3 split under-counted fast large regions. The fix lives
here.

Note the accounting subtlety (`1053-1066`): `mb_read_resident` is decremented at
queue-drop time so launches unblock immediately, while the physical unlink lags
on a clock. Under fast large reads the queued-but-unfreed set can run ahead of
the budget within one flush window. Suspect this window as the flood cause;
verify against a `garry.task_log` trace of a crop=0 run before changing it.

### E. The per-op cost function (already present)

`R/passes.R:861-889` (`.stage_bytes_per_px`) estimates each stage's per-pixel
resident footprint: `8*outer_max + 8*in_px + 16 + scan_px`. Used today for
chunk sizing (`.plan_chunk_dim`) and the compute-budget balancer. This is a
genuine per-op cost annotation already in the engine.

The gap: it estimates *memory* only. To make the fuse-vs-materialise call at A,
the pass needs two terms it does not have:

- **compute cost** (roughly FLOPs/pixel: an MLP matmul is expensive; an NDVI
  ratio is not).
- **data-movement cost** (bytes a materialised intermediate ships through
  /dev/shm to a separate pool, which fusion avoids).

## The decision the pass must make

For each `source_read -> compute` chain, choose one of:

1. **Fuse**: run compute on the read daemon, storing only the kernel output.
   Cost ~ read_bytes + compute_flops, spread across the N read daemons. No
   intermediate crosses shm. Bounded by read-daemon compute capacity.
2. **Materialise**: store the read window, ship it to the compute pool. Cost ~
   read_bytes + shm_move(read_window) + compute_flops on <=2 daemons. Keeps the
   warm pool busy; keeps wide kernels off the lean readers.

Choose fuse when its modelled wall-time contribution is lower given the current
pool widths (N read daemons vs C=2 compute) and the memory budget (D). For the
MLP the model should discover: materialise ships ~1.2 GB windows through shm to
2 workers, fuse runs the matmul across N readers with nothing crossing shm,
fuse wins. For single-band mask cleanup (the case A already fuses) fuse should
still win. For a plan that genuinely wants the warm pool, materialise wins.
Same pass, no per-op rule.

## Implementation sketch

1. **Extend the cost model (E).** Add compute-cost and movement-cost terms
   alongside `.stage_bytes_per_px`. Compute cost can start coarse: FLOPs/pixel
   from the stage's op vocabulary (matmul dims for `band_mlp`, elementwise = 1).
   Movement cost = read-window bytes / measured shm bandwidth. Keep it an
   estimate; calibrate against the MLP case where the answer is known.
2. **Replace the predicate at A (`750-771`).** Swap the structural chain
   (especially `band>1` at 762) for the cost comparison. Keep the correctness
   preconditions that are not policy (single consumer, single export, cpu
   device, dtype/halo gates at `808-817`): those are about what CAN fuse, not
   what SHOULD. Only the cost cut (762) and the "wide kernel stays on warm pool"
   assumption change.
3. **Fold B into the same decision.** Pool tag becomes an output: fuse -> runs
   on read daemon; materialise -> comp or read by cost, respecting the no-spill
   constraint (C, `1289-1292`).
4. **Respect C as a bound.** The pass reads the compute daemon count; it never
   assumes more than 2. Fusion is how it escapes the ceiling, not by raising it.
5. **Tighten D against the flood.** Fix the resident accounting / flush-window
   so `read_ok` actually bounds shm under fast large reads. This is the
   crop=0 enabler and is independent of A-B, but the same budget the placement
   pass consults.

## Validation plan

- **First case = the MLP predict.** If the cost pass independently chooses to
  fuse the 145-band MLP onto the read daemons and box-1 crop=2048 predict drops
  below hutan's 362s, the *mechanism* is validated, not a rule.
- **Regression = mask cleanup.** The single-band chain A fuses today must still
  fuse and must not regress the HLS morphology benchmark.
- **Generalisation = NDVI / focal / nested reduce.** These must route through
  the same pass with no new code and no regression against their current
  numbers (see the general-path memory: ndvi 11.97s, composite 1.01x).
- **crop=0 must complete.** After D is tightened, the full-extent predict must
  finish without the mori shm-flood, at a wall time consistent with the
  crop=2048 result scaled by extent.

## What is out of scope

- The Icechunk-style manifest. Analysed this session and deferred: it addresses
  metadata/open overhead at scale and virtual chunk references, neither of
  which is the current gap. The read win came from physically rewriting the
  cache layout, which no manifest substitutes for. Revisit the manifest only on
  a move to many-file object storage or a versioning requirement, and build it
  bespoke over garry's read coalescing rather than adopting Icechunk wholesale
  (R/anvl/COG stack vs Rust/Zarr/object-store). See the general-path and
  aef-multiband-read notes.
- Raising the compute daemon count. Ruled out by the thread-cliff measurement
  at C.

## Anchors to reread first

- `R/scheduler.R:750-771` (A, the predicate to replace)
- `R/scheduler.R:819, 832, 784, 1289-1292` (B, pool assignment + no-spill)
- `R/scheduler.R:462-478` (C, daemon-count rationale)
- `R/scheduler.R:1053-1066, 1224-1246, 1305-1314` (D, budgets + resident
  accounting)
- `R/passes.R:861-889` (E, the cost function to extend)
- `R/band_mlp.R` (the MLP op whose compute cost the model must estimate)
