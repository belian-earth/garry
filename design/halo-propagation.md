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
- `nan_rm` reductions INSIDE a halo stage compute the beyond-edge ring
  as the empty-set reduction (a nan_rm sum gives 0, a nan_rm mean
  gives 0/0 = NaN). See the section below: no window reads that value.
- Single-chunk in-memory collects trim per-export pads through the
  same `.exec_trim` as assembly (rank-3 included); raw store values
  materialise first.

## The ring inside a stage

A boundary is correct by construction, and a stage was not: a member
computes the ring too, so a NaN-ignoring window, a NaN-filling map, an
integer cast or a `count` left real-looking values past the raster, and
the next window in the stage read them as data. Two focals in one stage
gave 0 NaN cells where the same two across a materialised file gave 220.

Inside a stage now equals across a boundary. A member with
`required_halo > 0` (a focal or a patch) that reads another member, not a
stage input, reads its parent with the cells past the raster back at
`.sv_fill()` of the parent's declared dtype. That is one select per such
window and nothing for any other member. It changes what the window
reads, not the parent: a map or an export still sees the computed value,
and only a window moves a value onto the raster. A stage input needs
nothing, as the read or the boundary already set those cells.

**Position is a run-time input.** One compiled kernel serves every chunk
of a stage, so baking position in would multiply compiles by nine. A stage
with such a window takes `.ring_cells()`, four i32 counts (top, left,
bottom, right) at the padded input's level, as one input after its stage
inputs. A member at a lower pad sits `in_pad - pad` cells in from them. The
counts are per side, as a chunk smaller than the pad and one in from the
edge reaches past it by less than the pad. Cells grown onto an edge chunk
(`.sv_grow`) count as past the raster.

`.ring_windows()` is the one place that decides this. It follows from
the members and input nodes, which the kernel signature already holds, so a
stage without the pattern keeps its key, program text and inputs.

**Coverage.** Compute tasks, the host executor and fused reads pass the
counts; a program lists them as an `i32:4` input of every shape, and a
closure warm-up passes zeros. Row tiles and scan strips need a kernel with
no halo, which a stage with such a window never is. `.gd_host_kernel` runs a
whole grid, so its counts are the whole pad on every side, and
`.gd_replay_mask` masks the same way between chain members. The gradient
tape does not compose stages, so it takes the counts itself and marks those
cells invalid at its inputs. Its validity mask then carries them through
every map, and no ring value reaches a valid cell. Testing inputs for NaN
is not enough: a decode keeps its integer read, which holds 0 past the
raster.

Placement and size estimates are unchanged: the counts are 16 bytes. A ring
window adds one select and its position mask, 42 lowered ops at any radius
(20 to 62 at radius 1, 244 to 286 at radius 5). End to end on a 4096 x 4096
raster in 16 chunks that is about 1.3 ms per 1024 x 1024 chunk: +5 % at
radius 1, under 2 % at radius 5. Only the smallest windows show it, and it
adds 2 to 6 % on a 16-band 512 x 512 cube.

**A window over a decode reads NaN.** A map that names a float dtype over
integers keeps its integer read and still sees 0 past the raster, but a
window over it finds NaN, as it does over the same map in a file. It read
the map's 0 before.

**Morphology reads NaN as clear.** `apply_mask(open = , dilate = )`
promises scipy's constant-0 border, which odc-algo's `mask_cleanup` shares
(phase 11.2). It held because the mask predicate maps the NaN ring to 0. With
the ring back at NaN a product over the window would spread NaN inward from
the edge, by the chain's whole halo, and flagged cells would read clear:
235 of 278 cells on a small fixture at `open = 2, dilate = 3`. So `.erode` and
`.dilate` are boolean: a cell is set if it is above 0.5, the test
`apply_mask()` makes at the end, and NaN compares false. The border holds on
every route and across a boundary too.

Clearing NaN with a select per disk offset gives the same arrays and was
rejected on cost: 58 selects against the 3 ring selects at `open = 2,
dilate = 3`, 637 lowered ops against 453 (291 before the ring), and warm
kernel CPU of x1.17 to x1.53 against x0.89 to x1.11, the old product being
x1. Measured against that product, ring included, the first trace costs +6 %
on a 4096 x 4096 mask and +13 % on a 4-slice composite. Warm wall time holds
on the mask, at 0.78 s, and falls on the composite, from 0.26 s to 0.23 s.

Two answers move with this, both deliberately. A read of integer QA pads with
0, so a `where` holding 0 flagged the ring on the scheduler alone, 67 extra
cells on the same fixture at `open = 1, dilate = 1`. And a `where` function
that returns NaN on a raster cell spread it through the old product,
unmasking flagged cells around it; that NaN now reads clear at its own cell
and goes no further. On a 24 x 30 fixture at `open = 1, dilate = 1` this moves
25 cells, up to 11 in from the edge, and gives the 153 masked cells a numeric
`where` gives. It is the one move outside the ring. A `where` must return 0
or 1: a fraction now thresholds at 0.5 in the morphology, where the product
carried it.
