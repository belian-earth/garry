# Design note: multi-export collect (one plan, many sinks)

Status: **design, not started.** Written 2026-07-17, from the hutan
engine-comparison measurements (experiments/engine-cmp). Prerequisite for the
single-graph SI pipeline: everything from MLP predict downstream as ONE
garry graph with one execution.

## 1. Motivation: the measured gap

`collect()` executes one sink. A pipeline with several products re-runs the
shared upstream once per product, and small stages pay full plan/jit/read
overheads each. Measured on the real vm47 tail (2026-07-17, 8-core pool):

- Per-stage garry engines: smoother 9.6x, but the 2-8 s elementwise stages
  (calibration, fuse, ensemble, conformal) run 0.16-0.23x — each `collect`
  costs ~10-40 s of fixed overhead regardless of the math.
- `si_tail()` (cal/var/fuse built lazily INTO the Kalman scan): tail 354.6 s
  -> 174.6 s (2.03x). Of the 174.6 s, ~90 s is the smoother running TWICE
  (mean and sd are separate ScanNodes, two collects re-run the fused scan)
  and ~39 s the ensemble stage's own collects.

With multi-export, the tail is one smoother pass plus writes: ~50-60 s
(~6x), and the whole predict-downstream pipeline becomes one plan.

## 2. Target shape (the hutan SI pipeline)

Two phases, ONE boundary, placed after acquisition/decode:

- **Phase P (points, plain R)**: sample cells + GEDI shots -> all fits (MLP
  weights, calibration knots, Kalman MLE, tau_break, regime, conformal
  quantiles, bilateral sigma_r) computed POINT-SIDE — the dual-mode `g_*`
  bodies run untraced on `(T, n_points)` matrices, so the same kernels that
  execute the raster also produce the fit samples. Every break becomes a
  constant BEFORE the raster pass.
- **Phase R (raster, one graph)**: read -> dequantize [-> bilateral, ESD arm
  only, AT READ: read -> dequant -> bilateral -> stack, so exactly one set of
  ESD embeddings exists and no intermediate context tifs] -> per-year
  `mlp_project` per arm -> calibration map -> variance -> inverse-variance
  fuse -> Kalman scan -> ensemble mixture + growth scan -> conformal offsets.
  Sinks: si, pi_lo, pi_hi, smoothed, std, fused mean/var (+ per-arm cal when
  wanted). ONE collect.

## 3. API

```r
collect(list(si = ens_mean, lo = pi_lo, hi = pi_hi, smoothed = sm, ...),
        path = c(si = "si.tif", lo = "lo.tif", ...),   # or a dir + names
        ...)
```

- Input: a NAMED list of `LazyRaster`s on one graph (graph_import merges
  foreign graphs, as `scan_over()` does). Grids may differ per sink
  (reduced vs full axes) but must share the spatial grid.
- `path`: one path per sink (named vector or a directory); `path = NULL`
  returns a named list of arrays.
- Single-raster `collect(x)` unchanged; a LazyDataset keeps its current
  band-sink semantics.

## 4. Planner and executor

The internals are closer than they look — stages already carry export SETS:

1. **Plan**: `plan_lazy()` grows a multi-sink form: `plan@sinks` (named id
   vector) instead of the single `plan@sink`. Phase-A stage assignment is
   unchanged (it walks the whole reachable graph); the only change is that
   every sink's node id must appear in some stage's `@exports` (today only
   the sink stage exports; extend `.compose_stage_fn`'s export set to the
   union of sink ids landing in that stage).
2. **Shared execution**: one pass over the stages, per chunk, exactly as
   today. Each stage's chunk result is a named export list already; the
   executor routes each export belonging to a sink into that sink's
   assembly buffer / streamed write instead of discarding it.
3. **Sinks on different grids** (e.g. fused (t,y,x) and si (t,y,x) vs a
   (y,x) diagnostic): assembly is per-sink using that sink's grid — the
   existing 2-D and (outer,y,x) assembly paths cover both.
4. **Scheduler**: `.stage_kernel_sig` unchanged (exports are part of the
   sig already). Stream-write gating extends per sink.
5. **RAM**: one plan holding all years x arms x bands per chunk widens the
   working set (~1400 band-chunks/chunk for the SI graph); the existing
   `.plan_chunk_dim` RAM budget handles it by shrinking chunks — verify
   with a wide-graph test, and surface the chosen chunk size in verbose
   output.

## 5. Sibling-barrier fusion + CSE (the mean/sd double-run)

`kalman_smooth()` builds two ScanNodes over identical inputs; today each is
its own stage, so the scan executes twice even with multi-export. Fix in two
steps:

1. **Allow sibling barriers in one compute stage**: Phase-A currently roots
   a stage at each barrier. Extend the else-branch so a barrier node whose
   parents are all members/inputs of an existing compute stage MAY join it
   when their grids agree (they do: both scans preserve the parent grid).
   The merge-pass "don't fold a barrier root into a multi-input join" rule
   stays for cross-stage safety.
2. **Let XLA CSE dedupe**: with both scan bodies traced into ONE jitted
   stage fn, the two forward recursions are structurally identical and
   XLA's common-subexpression elimination collapses them. No new IR; a true
   multi-output ScanNode (emitting a named list, like `nv_scan`'s `out`)
   is the later, cleaner form if CSE proves insufficient — measure first.

## 6. What this unlocks, in order

1. `si_tail()` collapses to one collect: ~2.03x -> ~6x on the measured tail.
2. `kalman_smooth(outputs = c("mean","sd"))` stops double-running everywhere.
3. hutan `si_graph()`: the full predict-downstream pipeline as one plan
   (Phase R above), with Phase P point-side fits feeding constants.
4. The ESD read-side chain (read -> dequant -> bilateral -> stack) folds in
   once the small-halo focal fusion refinement lands (see
   benchmarks/README.md bilateral notes) — reader specifics deferred.

## 7. Validation

- Multi-export == N single collects, byte-identical, on: shared-upstream
  maps, a reduce + its input, scan mean+sd, mixed grids. Chunk-forced and
  distributed variants (the engine-comparison harness pattern).
- Kernel-sig regression: multi-export stage sigs distinct from single-sink.
- Wide-graph RAM test: a 12-year x 2-arm x 70-band synthetic graph plans
  chunks under the budget and completes on a small-RAM cap.
- Re-run hutan experiments/engine-comparison.R tail-fused stage: gate at
  >= 4x vs the legacy tail before flipping build_si defaults.

## 8. Open questions

- Partial failure: one sink's write fails mid-run — abort all (simplest,
  v1) or continue and report per sink?
- `plan_only = TRUE` returns the multi-sink plan; draw()/preview() of a
  multi-sink graph (preview the first sink? all?).
- gdal-direct fast path: stays single-sink (whitelist fallback), revisit
  after v1.
