# Sample sink: point sampling, polygon subsetting, in-graph fits

Date: 2026-08-13. Status: DESIGN, not scheduled. Origin: Hugh's
observation that solving point sampling would let model FITS join the
pipeline, removing intermediate disk from the fit path.

## Why

A fit consumes a SAMPLE, not a cube. Sample sizes are tiny next to the
rasters they come from: ramet47's SI models fit on GEDI shots, the AEF
vignette's k-means fits on ~100k pixels of a 7.5M-pixel scene.

Yet every fit-bearing pipeline today stages an intermediate raster
purely to get a table out of it, because extraction requires a
materialised file. ramet47 acquires ESD/AEF cubes to disk, then reads
them back at points; the AEF vignette fits on a whole separate coarse
read because there is no way to say "just these pixels". The missing
primitive is a NON-RASTER SINK that emits sampled values.

With it, the fit path becomes: STAC -> lazy reads -> fused decode ->
sample sink -> small table -> fit in R -> predict fused back through
the graph (`band_project` / `band_mlp` / a custom reducer, all
existing). Nothing hits disk on that path.

## Scope boundary (unchanged)

Geometry stays at the GDAL/PROJ boundary, resolved at PLAN time:

- points: transform to the grid CRS and compute cell indices on the
  host, exactly as STAC footprints are transformed today;
- polygons: `gdal_rasterize` to a zone raster, which then enters the
  graph as an ordinary lazy source.

No vector layer inside the engine, no per-pixel geometry ops, no
arbitrary R in the graph. The engine only ever sees cell indices and
rasters.

## The sample sink

Sketch: `sample_points(x, pts, ...)` over a `LazyRaster`/`LazyDataset`,
returning a lazy object whose `collect()` yields a table.

**Plan time (host).** Transform `pts` to the grid CRS; compute
`(row, col)` per point; drop or flag out-of-extent points; group point
indices by chunk. The planner then keeps ONLY chunks containing at
least one point -- a chunk filter over the existing chunk grid, not a
new grid concept.

**Execution (daemon).** The chunk kernel gains a gather export: for
chunk `c` with local indices `(r_i, c_i)`, emit `values[i, band, ...]`.
`prim_gather` exists upstream; a `g_gather` wrapper is the D9-insulated
way in. Payload is tiny, so these are plain R matrices in the store,
not raw payloads.

**Host assembly.** Concatenate chunk tables in ORIGINAL POINT ORDER,
not chunk-completion order, so results join back to point attributes
and are reproducible across runs and pool widths.

**Return shape.** The existing dim model carries if a sample result is
the collect() shape minus the spatial axes: `(point, band)` for a
composite, `(point, band, t)` for a time cube. Sinks are non-raster, so
`write_tif()` does not apply; a `write_parquet()`-style exit is a
later, separate question.

**Seams touched.** Planner (a non-raster sink kind + the chunk filter),
store (small table values), collect (assembly + ordering), scheduler
(sink handling that is not a write). Modest, but real: this is the
piece of engineering the whole idea rests on.

## Polygon subsetting

Rasterize at plan time, then three distinct uses, in increasing order
of new machinery:

1. **Mask to a polygon** -- expressible TODAY (`mask()` against the
   zone raster). No work needed.
2. **Extract cells in a polygon** -- the sample sink with a zone
   predicate instead of an index list. NOTE the difference from
   points: output size is UNBOUNDED (a polygon may cover millions of
   cells), so this needs either an explicit cap, a sampling fraction,
   or a streaming exit to parquet. Do not pretend it is small.
3. **Zonal statistics** -- reduce-by-key over the zone raster: the
   standing candidate in design/fixed-point-note.md's scope list.
   `prim_scatter` upstream is the substrate.

## Fit fusion, in tiers

**T1: host fit on a streamed sample.** Needs ONLY the sample sink.
Removes intermediate disk from the fit path. The fit itself stays in R
(kmeans, prcomp, ranger, torch -- anything), and prediction fuses back
through the graph as it already does. This is ~90% of the value and
the only tier worth scheduling on its own.

Honest limit: T1 is TWO collects with host work between (sample ->
fit -> predict), not one plan, because the predict depends on the
fitted object. The win is "no intermediate raster on disk", not "one
graph".

**T2: differentiable fits on device.** garry already has the unusual
ingredients -- a gradient tape (R/gradient.R, gated by the
grad-convergence tests) and fused forward passes. A linear/logistic/MLP
fit is a host-driven epoch loop whose STEP (forward, loss, backward,
update) is one fused device computation over the resident sample. The
sample is small, so this is cheap. Elegance more than necessity, but it
makes end-to-end differentiable pipelines possible.

**T3: iterative non-gradient fits in-graph.** k-means Lloyd decomposes
exactly into pieces garry has or wants: assignment (the
`nearest_center` reducer demonstrated in the AEF vignette -- already
ordinary user vocabulary), a scatter-mean update (reduce-by-key), and a
convergence loop (the fixed-point/While primitive queued at
ir-extensions-todo #1, pending anvl's iteration work). Both missing
pieces are ALREADY roadmap items; T3 is what falls out when they land,
not a separate ask.

## Measured: where the saving actually is (2026-08-14)

Benchmark (`benchmarks/sample-points-bench.R`, AEF tile, 61 km window at 30 m,
3 bands, 49 source tiles of 1024 px; each measurement in a FRESH process
so no route inherits a warm vsicurl cache):

| case | tiles touched | sample | collect | targeted |
|---|---|---|---|---|
| 200 clustered | 1/49 | 14.9 s | 16.2 s | 11.9 s |
| 200 scattered | 36/49 | 15.7 s | 15.4 s | 43.7 s |
| 5000 scattered | 42/49 | 15.1 s | 15.8 s | 35.8 s |

("targeted" = `gdalraster::pixel_extract` straight off the remote COG:
fetch only the tiles holding points, but read the SOURCE, no graph.)

Three findings, and they redirect the roadmap:

1. **Phase 1 gives NO fetch/compute saving** -- sample and collect are
   within noise everywhere. Its value is no disk round-trip, no
   whole-raster array in R, and the API. Do not claim speed for it.
2. **Per-point targeted reads are the WRONG answer**: 2.8x SLOWER for
   scattered points (43.7 vs 15.7 s), because a read per point trades
   garry's few big parallel windowed reads for thousands of
   latency-bound ones. This is the "per-point windowed reads" pattern
   already listed under "Explicitly not", now measured.
3. **Even at 1/49 tiles, targeted saved only 20%** -- the fixed cost of
   opening this remote COG (64 bands x 13 overviews of header) dominates.
   There is a floor under every strategy on headers this size.

**So Phase 2's justification changes.** The win is not skipping COMPUTE,
it is never ISSUING the read windows that hold no points -- keeping the
parallel high-throughput read pattern while cutting volume. Worth it for
spatially concentrated points (GEDI tracks, field plots); nothing helps
scattered points, which genuinely need the data. TILE COVERAGE, not point
count, is the number that predicts the saving, and it is cheap to compute
at plan time -- so a future planner could pick the strategy from it.

**And chunk pruning alone is COSMETIC** (verified 2026-08-14): a 2048^2
grid plans compute chunks of 1024^2 (4 chunks) against a source read
stage of chunk_dim 5120x5120 -- ONE window over the whole raster, because
read_target_px is 3.2e7. Skipping compute chunks while that single read
still runs fetches everything anyway. Phase 2 must therefore control READ
GRANULARITY, and the benchmark above brackets it: one big window is
15.7 s but unprunable, one read per point is 43.7 s and latency-bound.

**Preferred Phase 2 design: decompose the POINT SET, not the scheduler.**
Cover the points with a few bounding boxes, run one ORDINARY sub-plan per
box over that sub-grid, concatenate the tables. A smaller grid yields
smaller read windows automatically, so granularity solves itself, and
there is no scheduler surgery -- every sub-plan is a normal collect, so
none of the drain hazards below apply. Cost: k boxes = k sequential
drains (the pulsing multi-export fixed for grouped collects), so keep k
small and fall back to the single-plan path when the boxes cover most of
the raster anyway.

**Fallback, only if measurement demands it: true chunk pruning.** Safe
ONLY for sample sinks (a raster write needs every chunk, so the assembly
and streaming paths stay untouched by construction) and only when no
reduce_combine stage exists (a global x/y reduction needs every partial).
Hazards to clear first: `dep_left` is built from dependencies with no
existence check, so one skipped producer chunk hangs the drain forever;
`dep_of`/`elt_of` are positional in j (scheduler.R:854-855);
`fetch_reads_left` counts the full table; and out_of/.exec_assemble/
.exec_write_sink/sink_task_map all iterate seq_len(nrow(it)).

## Open questions

- **Sampling semantics.** Nearest cell by default. Bilinear/footprint
  sampling (GEDI's ~25 m footprint against 30 m cells) is expressible
  by aligning or focal-ing FIRST and then sampling -- keep the sink
  itself a pure gather rather than growing resampling modes.
- **Buffered sampling** (mean of a 3x3 around each point) is
  `focal()` then sample: free once sampling exists.
- **Sparse points vs read granularity.** Coarse reads mean a chunk
  holding one point still reads ~32 Mpx. Options: shrink read windows
  for sample-only plans, or accept it (local cubes do not care; remote
  sparse sampling would want a point-clustered read plan). Measure
  before optimising.
- **Out-of-extent points**: emit an NA row (keeps join alignment) or
  drop with an index attribute? NA row is the safer default.
- **nodata**: sampled NaN stays NaN (D8), so complete-cases filtering
  is the caller's job, as it is today.
- **Multi-export composition**: can one plan carry a raster sink AND a
  sample sink? Useful (write the composite, sample it for the fit, one
  read), and multi-export collect already exists.

## Explicitly not

- a vector geometry layer inside the engine;
- per-point windowed reads (a latency-bound access pattern, and a
  different design);
- arbitrary R in the graph (the standing scope rule).

## Related

- ir-extensions-todo #1 (scan/iterate, the While primitive) -- T3.
- ir-extensions-todo #14 (predict adapters for fitted R models) -- the
  other half of the fit story: what the fitted object becomes on the
  way back INTO the graph.
- design/fixed-point-note.md -- reduce-by-key zonal as an accepted
  scope candidate.
