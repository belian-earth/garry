# garry: implementation plan (phases 1-9, PoC-first)

## Context

garry replaces vrtility's VRT-as-IR model with an R-native lazy raster
array: GDAL (gdalraster) owns read/warp/write, anvl (XLA) is the sole
compute backend, mirai distributes chunk tasks, vaster does grid math,
S7 is the object system. The Phase 0.5 anvl spike is done (verdict GO,
`design/anvil-spike.md`); the backend decision is final (Linux-first).
This plan turns the design doc's phases into an executable roadmap where
every phase ends in a named test gate whose passing LOCKS a design
decision, so later phases never reopen it.

User decisions (2026-07-05): License MIT; extent order = GDAL/sf bbox
`(xmin, ymin, xmax, ymax)` user-facing and internal (vaster calls
reorder via one helper); PoC demo runs on a local Sentinel-2 GeoTIFF.

PoC milestone = Phases 1 → 2 → 3 → 4a → 5, then go/no-go review before
4b/6/7. Sequencing: 1 before 2 (GridSpec shape changes propagate into
every Node); 3 before 4a (planner golden tests run on stubs + pure-R
oracle, isolating planner bugs from GDAL/anvl); 4a before 5 (executor
gate needs real pixels with terra as external reference).

## Step 0 — Housekeeping (before Phase 1)

- Commit the spike work currently uncommitted (design/spike/*,
  design/anvil-spike.md, design doc cross-refs, DESCRIPTION anvl fix).
- DESCRIPTION: License MIT + file LICENSE; Authors@R real; min R 4.3;
  pin SHAs in Remotes (`r-xla/anvl@<sha>`, `hypertidy/vaster@<sha>`).
- CI (GitHub Actions, Linux only): R release + devel;
  extra-repositories r-xla.r-universe.dev + mlverse.r-universe.dev;
  system libgdal; two tiers — fast (no anvl, every push) and full
  (anvl CPU PJRT, nightly/on-label); cache the 61 MB PJRT plugin;
  CUDA tests skip-if-unavailable.

## Phase 1 — Grid primitives and conventions

Files: `R/grid.R` (surgery), `R/chunk_grid.R` (keep machinery, rewrite
`cross_grid_window`), new `R/options.R` (policy constants).

- Extent stays `(xmin, ymin, xmax, ymax)` (user decision). Add
  accessors `xmin()/xmax()/ymin()/ymax()/res()`; nothing else indexes
  `@extent` positionally. Single helper `as_vaster_extent()`
  (`ext[c(1,3,2,4)]`) at every vaster call site — the only reorder
  point.
- CRS: canonicalise to WKT2 via `gdalraster::srs_to_wkt()` at GridSpec
  construction; `grid_equal()` compares canonical strings, falls back
  to `srs_is_same()`. Validator gains transform/extent/dim coherence
  check.
- Dtype vocabulary (anvl set: f32 f64 i8-i64 u8-u64 pred) +
  table-driven `dtype_promote()` with XLA-style rules (f32+i32→f32,
  never R's f64; division always floats).
- `cross_grid_window`: same-CRS keeps exact affine math; cross-CRS
  delegates to `gdalraster::transform_bounds()` (GDAL densifies) plus a
  margin. Documented as planning estimate only — execution windows for
  warps are owned by GDAL's warper (4b). Over-estimate safe.
- `chunk_iter` gains `shape_id` (interior/right/bottom/corner — the ≤4
  shapes invariant from the spike).

Gate (all must pass + R CMD check clean):
- `test-grid-convention.R` — extent ordering + accessors locked;
  vaster-adapter round-trip.
- `test-grid-crs.R` — EPSG string, WKT2, proj4 construct equal grids;
  3857 unequal.
- `test-dtype.R` — full pairwise promotion table asserted.
- `test-chunk-grid.R` — property tests (~200 random draws): exact
  tiling, halo clipping at edges, snap idempotence, ≤4 shapes.
- `test-cross-grid-window.R` — same-CRS exact vs brute force; cross-CRS
  (4326↔3857, high-latitude UTM) containment of a 400-point densified
  boundary; regression case the old 2-corner code fails.

## Phase 2 — IR and graph correctness

Files: `R/graph.R` (+`graph_import`), `R/node.R`, `R/generics.R`,
`R/lazy_raster.R`, new `R/ops.R`.

- `graph_import(dst, src, root_id)`: copy reachable subgraph,
  renumber, dedup SourceNodes by (path, band, grid). `.lazy_binop`
  auto-merges graphs (fixes the a+b landmine); grid mismatch still
  errors (align stays explicit). Result dtype = `dtype_promote()`.
- Named dims on GridSpec (`c(x=, y=[, t=, band=])`). Real
  `output_grid(ReduceNode)`: reduce t/band drops the entry; reduce x/y
  collapses to 1 with extent kept, transform rescaled; mean/median on
  ints promote f32.
- Nodata threading: SourceNode gains `nodata`; integer source with
  nodata promotes to f32 (NaN carrier); `src_nodata → NaN` rewrite
  recorded for the executor.
- `R/ops.R`: garry op vocabulary (g_ifelse, g_is_nodata, g_pad,
  g_shift_slice, g_cast, g_sum/mean/min/max/median(nan_rm=), bitwise
  family). This phase: pure-R reference implementations only — NOT a
  user execution path (one-compute-path rule stands); it is the
  permanent test oracle and lets Phase 3 golden tests run without anvl.
  Phase 5 adds traced nv_* dispatch. No `nv_*` outside ops.R, ever.

Gate:
- `test-graph-merge.R` — same-path sources dedup to one node; distinct
  paths two; toposort valid post-merge; diamonds preserved; right
  operand still usable.
- `test-ir-output-grid.R` — Source→Map→Focal→Reduce(t), Reduce(x,y),
  Stack→Reduce(band): every node grid hand-checked.
- `test-nodata-dtype-ir.R` — i16+nodata→f32 downstream; f32+i32→f32;
  mean(i32)→f32; g_cast respected.
- `test-ops-oracle.R` — every op vs base-R semantics on NaN-bearing
  arrays (becomes the anvl parity harness in Phase 5).
- `test-backend-insulation.R` — grep R/ (minus ops.R) for `nv_`; fail
  on hit.

## Phase 3 — Planner

Files: new `R/plan.R`, `R/passes.R`, `R/collect.R`, `R/dot.R`.

- `Plan`/`Stage` S7 classes. Stage = member ids, ONE composed closure
  built from ops.R vocabulary (focal members expanded via stencil()
  so the same closure runs under the pure-R oracle and under jit()),
  total halo, ChunkGrid, kind (source_read/compute/reduce_combine/
  warp/sink), device tag, input stage ids.
- Passes: validate; halo propagation (reverse walk, reset at barriers;
  source/warp-fed halos satisfied by enlarged GDAL windows — free);
  focal placement check — focal ONLY in stages fed directly by
  source_read/warp, else structured error (mid-graph halo store is v2;
  no silent rechunk); compose; chunking (target ≥1 MP/chunk per spike
  dispatch numbers, block-snapped, RAM-capped; constants in
  R/options.R); reduce decomposition — algebraic reductions
  (sum/mean/min/max/count) split into per-chunk partial +
  reduce_combine; median/quantile over x,y REJECTED by planner;
  median over t/band (within-chunk) allowed; export.
- `collect(x, plan_only = TRUE)` returns the Plan (permanent
  introspection path); `plan_dot()` for DOT output.

Gate (stub sources; no GDAL, no anvl):
- `test-planner-golden.R` — four hand-traced toy pipelines (NDVI
  two-source; source→map→focal(1)→reduce(mean x,y); cross-graph add;
  align→map) with expected stage count/kinds/members/halos as R
  literals. Changing planner output means consciously editing goldens.
- `test-plan-halo.R` — focal(1)|>focal(2) → source window +3; halo
  resets across reduce.
- `test-focal-placement.R` — reduce→focal errors with condition class.
- `test-plan-oracle-exec.R` — execute golden plans chunk-by-chunk via
  the pure-R oracle == whole-array result. Chunking-correctness proof
  independent of anvl.
- `test-plan-dot.R` — DOT snapshots.

## Phase 4a — GDAL read adapter (PoC-lite)

Files: new `R/gdal_adapter.R` (the ONLY file speaking GDAL
conventions), `tests/testthat/helper-fixtures.R`, edits to
`R/lazy_raster.R` (real `lazy_source()`, stub moves to test helper).

- `gdal_grid_spec(path)`: extent (already GDAL order — no reorder
  needed, one bonus of the user's convention choice), WKT2, dtype map
  GDT_*→garry, block size, nodata. `gdal_read_window()` returns R
  matrix in garry orientation — LOCK: `[row=y, col=x]`, north-up row 1.
  Nodata→NaN promotion happens here, never later. Handle cache (open
  once per path per process).
- Fixtures generated at test time into tempdir() via
  `gdalraster::create()`: asymmetric gradient f32; tiled i16 with
  nodata; EPSG:3857 variant.

Gate:
- `test-gdal-grid.R` — fields vs `terra::rast()` metadata for all
  fixtures.
- `test-gdal-read-orientation.R` — asymmetric fixture whole + windowed,
  bit-exact vs terra at spot-checked world coordinates (kills the
  transpose/flip bug class).
- `test-gdal-read-window.R` — ragged edges, halo-enlarged windows,
  i16 nodata→f32 NaN, bit-exact vs read_ds.
- Grep test: no `gdalraster::` outside gdal_adapter.R (except srs_*/
  transform_bounds in grid.R).

## Phase 5 — Single-threaded anvl executor (PoC completion)

Files: `R/ops.R` (traced nv_* dispatch), new `R/stencil.R`,
`R/executor.R`; wire `R/collect.R`.

- `stencil(fn, radius, boundary)`: pad + (2h+1)^2 shifted slices +
  combine (productise spike script 02). `focal(radius=)` mandatory.
- Executor: topo-walk; per chunk read halo-padded window → upload once
  → run stage's jit()-wrapped closure with intermediates DEVICE-SIDE
  within the stage → trim halo → egress at stage boundaries only.
  anvl's shape/dtype-keyed LRU jit cache IS the kernel cache (do not
  build our own — locked). reduce_combine runs in R on small partials.
  Sink: in-memory array (GDAL write is 4b).

Gate:
- `test-ops-anvl-parity.R` — every op traced vs oracle on NaN-bearing
  f32/i32, f32 tolerance.
- `test-executor-e2e.R` — source|>(+1)|>focal(mean,1)|>reduce(mean)
  == whole-array pure-R to 1e-6; NDVI pipeline vs terra.
- `test-chunk-invariance.R` — identical results across chunk dims
  {17x23, 32x32, 64x48, whole}, with focal halos. THE correctness gate.
- `test-kernel-cache.R` — ≤4 compiles per stage on a ragged grid;
  cached dispatch <5 ms median.
- `test-nodata-e2e.R` — i16+nodata through map+focal+reduce(nan_rm) vs
  terra na.rm=TRUE; all-nodata cells NaN.
- `test-allocator-stress.R` — 500+ chunk loop, bounded RSS/device
  memory (risk gate before mirai multiplies it by N daemons).

**PoC CHECKPOINT**: demo script in design/ — local Sentinel-2 GeoTIFF →
NDVI → 5x5 focal mean → global stats, one command, plus
plan_only introspection. Go/no-go review before 4b/6/7.

## Phase 4b — Warp and write

New `R/warp.R` + adapter additions. `align(x, to=)` → WarpNode;
execution via `autoCreateWarpedVRT`/`rasterToVRT` + windowed reads of
the warped VRT (GDAL computes source windows — definitive fix for the
cross-CRS window issue; our cross_grid_window stays a cost estimate).
Write sink: `create()` + block-aligned band writes; NaN → sentinel
demotion for integer outputs.

Gate: `test-warp.R` (vs terra::project per-resampling tolerances;
VRT window-read == whole-warp crop), `test-write-roundtrip.R`
(write→read bit-exact incl. i16 sentinel), `test-align-pipeline.R`.

## Phase 6 — Differentiable pipelines

**6.0 first, before any API work**: `test-grad-nanrm.R` — gradient()
through nan_rm=TRUE reductions vs finite differences on NaN inputs.
If it fails, locked fallback: planner rewrites nan_rm reductions to
mask-multiply form (sum(x*mask)/sum(mask), zero-substituted) inside
differentiated kernels. Decided here because it constrains kernels.

Then `R/gradient.R`: gradient over LazyRaster pipelines via
value_and_gradient (returns list(value, grad$arg)); planner rejects
Warp barriers and focal-median on the tape with documented errors;
chunked gradients via linearity for algebraic reductions.

Gate: `test-grad-fd.R` (vs finite differences, 5 decimals);
`test-grad-convergence.R` (3x3 kernel recovery through the full
product path, <1e-5 in ≤500 steps); `test-grad-linearity.R` (chunked ==
unchunked across chunk sizes); `test-grad-barriers.R` (condition
classes for Warp/focal-median).

## Phase 7 — mirai distribution

New `R/scheduler.R`: ready-queue keyed (stage_id, chunk_idx), mirai
dispatch, in-flight cap for back-pressure. Inter-stage store v1:
tempdir GTiff/qs per (stage, chunk) — no halo store needed thanks to
the Phase 3 focal-placement lock. Device pools: cpu_pool +
one-process-per-GPU cuda_pool; XLA preallocation capped via env vars.

Gate: `test-mirai-equivalence.R` (distributed == Phase 5 executor on
every golden pipeline — same Plan, two executors);
`test-mirai-scaling.R` (≥0.7xN for N in {2,4}, slow/nightly);
`test-mirai-cuda.R` (skip-if-no-CUDA GPU pool smoke).

## Phase 8 — STAC/collections

Port vrtility STAC ingest → `lazy_stack()`/collection constructors
emitting Source/Warp/Stack nodes. Gate: `test-stac-composite.R` —
reproduce a median STAC composite vs vrtility output within tolerance
(median over t is within-chunk: allowed per Phase 3 lock).

## Phase 9 — Ergonomics

print/format/str, `[` subsetting (window pushdown to SourceNode),
vignettes, bench/ suite with regression thresholds seeded from spike
numbers (59 ms 3x3-mean/2048^2; 410 us dispatch). Gate: snapshot tests
+ committed bench baselines.

## Decision register

| # | Decision | Locked | Guarding test |
|---|---|---|---|
| D1 | Extent = (xmin,ymin,xmax,ymax) everywhere; vaster reorder via one helper | P1 | test-grid-convention.R |
| D2 | CRS = canonical WKT2 + srs_is_same | P1 | test-grid-crs.R |
| D3 | XLA-style dtype promotion (f32+i32→f32) | P1 | test-dtype.R |
| D4 | ≤4 chunk shapes; no pad-to-uniform | P1 | test-chunk-grid.R |
| D5 | Cross-CRS planning windows contain truth; warper owns execution windows | P1/P4b | test-cross-grid-window.R, test-warp.R |
| D6 | Binary ops auto-merge graphs; source dedup | P2 | test-graph-merge.R |
| D7 | Named dims; Reduce grid algebra | P2 | test-ir-output-grid.R |
| D8 | NaN-sentinel nodata; int+nodata→f32 at source | P2/4a/5 | test-nodata-*, test-gdal-read-window.R |
| D9 | ops.R is the only nv_* surface | P2 | test-backend-insulation.R |
| D10 | Stage = one oracle-executable closure; plan schema | P3 | test-planner-golden.R, test-plan-oracle-exec.R |
| D11 | Focal only in source/warp-fed stages; halo store = v2 | P3 | test-focal-placement.R |
| D12 | Algebraic-only distributed reductions; median only over t/band | P3 | planner rejection + goldens |
| D13 | Orientation [y,x] north-up; GDAL quarantined to adapter | P4a | test-gdal-read-orientation.R + grep |
| D14 | Device-side within stage; anvl LRU = kernel cache; stencil = pad+shift; radius mandatory | P5 | test-kernel-cache.R, test-chunk-invariance.R |
| D15 | Gradient stops at Warp; no focal-median AD; nan_rm-vs-mask formulation | P6.0 | test-grad-nanrm.R, test-grad-barriers.R |
| D16 | One process per GPU; distributed == single-threaded | P7 | test-mirai-equivalence.R |

## Risk register

| Risk | Mitigation | Phase |
|---|---|---|
| anvl pre-1.0 churn | SHA pins; D9 confines breakage to ops.R; suite = churn detector | continuous |
| Allocator under chunk throughput | stress gate before distribution | P5 |
| gradient + nan_rm NaN poison | gate first; mask-multiply fallback pre-designed | P6.0 |
| GDAL↔R orientation bugs | adapter quarantine + asymmetric bit-exact tests | P4a |
| Cross-CRS window under-read | containment tests; GDAL owns execution windows | P1/P4b |
| Transfer overhead on trivial pipelines | fusion mandatory; bench thresholds | P5/P9 |
| GPU contention / XLA prealloc | one-proc-per-GPU; prealloc caps | P7 |

## Verification

Each phase gate is its verification. Continuous: `R CMD check` clean;
fast CI tier green per push; full tier (anvl) nightly. PoC checkpoint
is the human review: the Sentinel-2 demo runs end to end and the plan
introspection reads sanely.
