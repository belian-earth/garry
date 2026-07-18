# Cross-stage halo propagation: padded exports (D22)

## Problem

Focal (halo-bearing) work is only executable in a stage fed directly by
source or warp stages: the executor satisfies a halo by enlarging the
GDAL read window, and that mechanism exists only at the leaves. A stage
fed by other compute stages receives exactly chunk-core-sized values,
so the D11 placement check refuses the plan
(`garry_focal_placement_error`). Consequences on real pipelines:

- `hutan::embed_read` (raw FSQ -> 72 fused decode maps -> stack -> 3x3
  bilateral) must materialise the decoded cube to disk and re-read it
  in a second execution.
- The bilateral e2e benchmark could not fuse read+decode+filter, so the
  garry arm carried a full store round-trip rustyfilters does not pay.
- Any focal over a computed intermediate (filter after band math, focal
  over a t-reduce composite, focal after `scan_over` output) is
  refused rather than streamed.

An earlier idea ("tier 1", unbuilt) special-cased pointwise chains by
fusing them into the focal stage. It is subsumed by this design and is
not implemented: with padded exports, *any* upstream stage shape works,
and fusion remains a separate locality optimisation with its own
existing rules.

## Decision D22

Any stage can be asked to emit spatially padded chunks. A per-stage
`out_pad` is propagated backwards over the stage DAG at plan time;
stages compute their chunk window enlarged by `out_pad` (the "ring"),
and consumers receive values carrying at least the padding they need.
Overlapping ring cells are recomputed by neighbouring chunks rather
than exchanged: for the target workloads (radius-1 to radius-2 kernels
on ~1k-pixel chunks) the ring is well under 1% of cells, and recompute
keeps the scheduler free of cross-chunk communication and ordering.

The D11 *mechanism* (padded reads at source/warp leaves) is unchanged
and remains the base case; the D11 *restriction* (focal stages must be
leaf-fed) is deleted. The one remaining refusal is a `reduce_combine`
producer asked for padding: a spatially reduced value has no ring to
compute, and a focal over a scalar is meaningless.

## Model

Notation per stage `S`: `halo(S)` is the existing within-stage halo
(`.stage_halo`: padding S's members consume from S's inputs).
`out_pad(S)` is new. Define the padding S needs on its inputs as

    need(S) = halo(S) + out_pad(S)

and propagate reverse-topologically (sinks first) over the final,
post-merge stage DAG:

    out_pad(S) = max over consumers C of S of need(C),   0 if none.

Source and warp stages keep their existing rule generalised: their
read-window halo becomes `max(need(C))` over consumers (today it is
`max(halo(C))`).

### Per-export pads

A stage's exports do not all carry the same padding. Members upstream
of a focal member hold `need(S)` cells; the focal consumes `radius`;
post-focal members hold less. The composed closure already tracks this
"remaining pad" per member at run time; D22 mirrors that walk statically
in the planner and records `export_pads`, one integer per export, on
the Stage. The runtime walk and the static walk are the same algorithm
over the same specs, so they cannot disagree.

This makes the multi-export + focal interaction exact: in the
embed_read plan the decoded stack is BOTH a sink export and the
bilateral's input, in one stage. Its export carries pad 1 (written to
disk trimmed by 1); the focal's export carries pad 0.

### Consumer contract

Every input-gather site already trims producer padding down to the
consumer's expectation with `extra = producer_pad - halo(C)`. The
generalisation is uniform:

    extra = export_pad(producer export) - need(C)     (>= 0 by construction)

Sink writes and in-memory assembly trim each export's `export_pads`
entry (today they trim `.exec_out_pad`, which is nonzero only for
source/warp sinks).

## Why ring recompute (and not halo exchange)

- Cost: a radius-r ring on a w x h chunk core is
  `(2r(w+h) + 4r^2) / (wh)` of the cells — 0.4% for r=1 at 1024^2.
  Recomputing decode arithmetic or even a t-reduce over that ring is
  noise against the read and store costs.
- Chunks stay independent: no new task edges, no completion ordering,
  no partial-chunk state in the store. The scheduler's ready-queue,
  launch-order invariant, byte budget, and shm lifecycle are untouched.
- Correctness is compositional: padding a stage's inputs and computing
  the same pure function yields the padded output, because every
  compute member is either pointwise over space (map/stack, and
  reduce/scan whose `over` axis is non-spatial — they vectorise over
  trailing y,x) or an explicit stencil (focal) that consumes pad. There
  is no operation whose value at a pixel depends on chunk placement.

Pads compound naturally: focal feeding focal across a stage boundary
gives the producer `out_pad = r2`, its own inputs `r1 + r2`, and so on.
Deep focal towers would grow the ring; nothing in the SI pipeline
exceeds two, and the planner can warn on pathological pad/chunk ratios
later if one appears.

## Implementation map

Planner (`R/passes.R`):
- After `.merge_stages`, compute `out_pad` per proto (reverse pass over
  `inputs`), then `export_pads` per stage via the static pad walk.
- Source/warp halo inheritance loop uses `need(C)`.
- Replace the D11 abort with the reduce_combine-pad refusal.
- `.compose_stage_fn` gains `out_pad`; inputs start the pad walk at
  `halo + out_pad` instead of `halo`.
- `.trim_to_pad` becomes rank-general (trim the LAST two dims; the
  traced path already is, the untraced path and the nrow/ncol size
  computation are not — same latent cube bug class as the `.eval_node`
  focal window fix).
- `.stage_kernel_sig` includes `out_pad` (the composed fn's behaviour
  depends on it).

Executors (`R/executor.R`, `R/scheduler.R`):
- `.exec_out_pad(stage)`: source/warp -> `halo` (unchanged); compute ->
  `out_pad`.
- `.exec_in_meta` reports the producer's per-export pad; both gather
  sites trim by `pad - (halo + out_pad)`.
- Rank-3 trims: `.exec_trim` for `(outer, y, x)` arrays, `.sv_trim`
  for rank-3 raw payloads; `.exec_write_chunk` / `.exec_assemble` lift
  their `pad == 0` assertions for stacked chunks.
- Streaming sink writes trim the sink node's `export_pads` entry.
- Compute-on-read fuse specs carry the fused stage's `out_pad` (the
  fused kernel's output is core + 2*out_pad, not core; the coarse-read
  split slices grow accordingly).
- Jit warm-up shapes use `halo + out_pad`.

Unchanged by design: chunk tables and store keys (pads live in the
values, not the tiling); Phase-A narrow-focal fusion rule and the merge
pass's no-halo-merge guard (now purely locality/cost choices — the
comment loses its correctness claim); gdal-direct whitelist (plans
using D22 fall back to the standard executors); gradient tape.

## Validation

- Decode -> stack -> bilateral in ONE collect equals the materialised
  two-step reference: memory, file, and distributed modes; with the
  multi-export form (raw + ctx + qa) checking the padded sink export
  trims correctly.
- Focal over `reduce_over(t)` output and over `scan_over` output equal
  their two-step references (ring recompute across a barrier).
- Cross-stage focal towers (focal, join, focal) accumulate pads.
- Raster-edge chunks: NaN ring beyond the extent, identical to the
  leaf-fed behaviour.
- Global (spatial) reduce feeding a focal raises the reduce_combine
  refusal.
- Kernel-sig regression: identical stage at different `out_pad` gets a
  different signature.
- `hutan::embed_read` drops to a single execution and its parity test
  still passes (the acceptance case).

## Recorded findings (implementation)

- Beyond-edge ring masking is required, not optional: the FSQ decode's
  integer casts map the NaN ring to finite garbage. `.exec_mask_edge`
  re-presents beyond-raster cells as NaN on every padded stage export
  (and after fused compute-on-read kernels). Gated by the
  materialise-first parity test's NaN-pattern assertion.
- `nan_rm` reductions INSIDE a halo stage define the beyond-edge ring
  as the empty-set reduction (a nan_rm sum gives 0, a nan_rm mean
  gives 0/0 = NaN). This is pre-existing classic-path semantics
  (focal-over-reduce fed by sources behaves identically) and is NOT
  changed by D22; only stage BOUNDARIES guarantee NaN. Exact
  materialise-first parity for sum-like reductions needs
  `nan_rm = FALSE` or an explicit validity gate in the body.
- Single-chunk in-memory collects trim per-export pads through the
  same `.exec_trim` as assembly (rank-3 included); raw store values
  materialise first.
