# IR extension TODOs (deferred)

garry's IR is a finite DAG of `{Source, Map, Focal, Reduce, Warp, Stack,
Fused}`. Map and Focal already carry a `@fn` (arbitrary anvl kernel); Reduce
does not. Two additions would close most of the gap to a general array engine
without adding a geometry/vector layer (explicitly out of scope for garry).

## 1. Scan / iterate node (higher effort, highest leverage)

The IR has no data-dependent iteration or cumulative scan, so an entire class of
spatial algorithms is inexpressible, not just unimplemented:

- connected components (`patches`/`clump`)
- Euclidean & cost-distance transforms (`gridDistance`, `costDist`)
- flow accumulation / watershed / drainage
- region growing / segmentation, viewshed
- cumulative ops along a dim (`cumsum`-style)

A single `ScanNode` / `IterateNode` unlocks all of these. XLA exposes `While`
(and `cumsum`/associative-scan) underneath PJRT, so the compute primitive
exists; the work is a new IR node + planner/executor handling (loop-carried
state, halo/dependency bookkeeping for the propagating cases) and deciding which
of these must run whole-grid (most iterative transforms need the full frame, not
chunked tiles). Deferred by Hugh 2026-07-10; wanted available, not now.

**Watch upstream (2026-07-14):** the compute substrate is under active
development in anvl -- branches `iterate-edge-cases-334`, `cum-primitives` /
`cum-primitives-clean`, `higher-order-prim`, `feat-dynamic-slice` on
r-xla/anvl. Revisit this node once a `While`/scan/cumulative primitive lands in
an anvl release; building the ScanNode against the settled primitive avoids
tracking a moving API. No current garry feature depends on it, so it can wait.

## 2. Custom reducer fn on ReduceNode -- DONE

`reduce_over(x, fn, over)` now accepts an anvl reducer `fn(x, dims)` (carried on
`ReduceNode@fn`, `op = "custom"`), run by the shared `.eval_node` so the oracle
and the distributed scheduler behave identically. Supported over `t`/`band`
(each spatial chunk holds the full axis); a custom reducer over `x`/`y` errors
(no algebraic partial/combine). Tests in `test-reduce-custom.R`. This lets a
user collapse the time axis with arbitrary anvl math and return derived
parameters -- anvl has the dense linear algebra (`nv_matmul`, `nv_transpose`,
`nv_solve`, `nv_qr`, `nv_inv`, `nv_svd`), so per-pixel fits are expressible:

- linear / polynomial temporal trend (slope, intercept per pixel)
- harmonic / seasonal regression (phenology)
- robust fits, any "collapse T -> coefficients"

e.g. per-pixel OLS over time: `beta = nv_solve(Xt X, Xt y)` batched over pixels,
reducing the T axis.

Why Reduce is closed while Map/Focal are open: the scheduler decomposes named
reduces across chunks (mean = sum + count, etc.) and a custom reducer has no
auto-combine (monoid). But the composite / whole-cube path already materialises
the full reduce axis per tile, so a custom reducer drops in cleanly THERE first;
the chunked scheduler path would need an optional user-supplied combine fn (or to
force whole-axis). Smaller and static-shape (no iteration) vs the scan node.

## 3. Multi-band (multivariate) reductions -- geometric median / medoid

A per-band temporal median is band-SEPARABLE (each band reduced independently,
the current composite shape) and can yield a spectrum matching no real
observation. A geometric median (L1 / spatial median) and a medoid are
MULTIVARIATE: for each pixel they reduce over time but must see the full BAND
vector at every time step jointly. vrtility's `multi_band_reduce` -- valued by
Hugh -- does exactly this.

Feasibility is good because the substrate exists:
- The dim model is 4D (`.dim_names = c("x","y","t","band")`), so a `(band, t, y,
  x)` cube is representable.
- `lazy_stack(along = "band")` assembles it (stack per-time `(band,y,x)` slices,
  or per-band `(t,y,x)` cubes along band).
- The custom reducer (#2) is the hook: `reduce_over(cube4d, fn, over = "t")`
  reduces t while KEEPING band -- `.reduce_grid` drops only `t`, and the reducer
  receives the whole `(band,t,y,x)` array, so it operates across bands.

Compute is expressible in anvl (batched over pixels, band axis intact):
- medoid: pairwise inter-time band distances -> argmin total distance -> gather
  the winning time's vector. STATIC, expressible today.
- geometric median: Weiszfeld iteration. Fixed-K unrolled = static, expressible
  today; convergence-based wants the Scan/Iterate node (#1).

Work to do (not from scratch): (a) verify the 4D stack + multi-band custom reduce
runs end-to-end via the general scheduler -- it will NOT match the per-band
composite fast path (`.cd_spec`), so it falls to the scheduler, which keeps
non-spatial dims (t AND band) full per spatial tile, so a reduce over t seeing
band should work per chunk; (b) ship geometric-median (fixed-iter Weiszfeld) and
medoid as reference reducers; (c) a `multi_band_reduce(cube, fn)` convenience
wrapper matching vrtility's ergonomics; (d) later, a composite-fast-path variant
for the multi-band shape if it becomes hot. Deferred by Hugh 2026-07-11.

## 5. Grouped-collect read pipelining (observed 2026-08-06)

`group_by_time() |> collect(path = "{group}")` runs one plan per group,
sequentially: the network profile pulses (fetch burst, then idle
assemble/compute/write, x n_groups) instead of the single-plan
fetch-first drain's solid saturation. Per-group fetch counts are also
small (one tile x few assets), so no single group saturates the link.
Candidate: prefetch group N+1's read tasks while group N computes and
writes -- either a shared scheduler across group plans or a lookahead
fetch queue. Surfaced by the OCM vignette's materialise-per-day step.

RESOLVED 2026-08-06: .collect_groups now routes multi-group collects
through multi-export (one plan, one sink per group; per-sink band
names via collect(band_names = <named list>)). All groups' reads enter
one ready queue and drain under fetch-first priority. Measured on the
Zurich 9-date materialise: 39 s (per-group loop, pulsing) -> 24.8 s
(one plan, continuous drain). plan_only keeps the per-group loop.

## 6. unscale = TRUE: discovered scale/offset applied at read (2026-08-07)

GDAL rasters carry per-band scale/offset metadata (S2 L2A baseline-04:
scale 0.0001, offset -0.1 in raster:bands terms; often absent from
STAC metadata but present in the TIFF). DONE 2026-08-07
(branch scale-and-write-tif, with #8; resolution below). Naming decided by Hugh: the
argument is `scale` on lazy_source() / lazy_dataset(), default
FALSE; `scale = TRUE` applies the discovered affine at read (not
`unscale = TRUE`). Original proposal: an explicit flag that reads GetScale/GetOffset at discovery (the D8
nodata pattern) and fuses the affine into the read kernel when
non-trivial. NOT auto-on: silent value rescaling is the value-space
version of silent resampling. No memory cost in garry (unlike VRT
unscale, which promotes to Float64): two flops/px inside the already-
f32 fused read.

Traps recorded:
- Ordering: sentinel -> NaN BEFORE scaling (a scaled sentinel stops
  matching).
- Per-ITEM heterogeneity: the S2 baseline-04 cutover (2022-01) puts
  different offsets inside one band's time stack. Plain sources
  discover per slice and are fine; the STAC fast path probes ONE
  asset per band against a declared grid, so v1 would assume
  collection-homogeneous scaling and must document the caveat.
- Per-slice maps with DIFFERING constants break .cd_fn_sig slice
  homogeneity -> composite_direct fast path fragmentation; check
  before shipping.

Vignettes keep the explicit `(ds * 0.0001) - 0.1` arithmetic
regardless: teaching that the offset exists is the point; the flag is
sugar for those who know.

## 7. cog = TRUE: cloud-optimised GeoTIFF output on collect (2026-08-07)

Proposal (Hugh): a `cog = TRUE` flag writes a COG instead of a plain
GeoTIFF. Default FALSE keeps current behaviour and cost. SURFACE
SUPERSEDED by #8: the flag lives on `write_tif()`, not `collect()`;
the mechanics below stand.

Implementation shape is fixed by GDAL: the COG driver is
CreateCopy-only (overviews precede full-res data, strict IFD
ordering), so it cannot be the streaming sink. `cog = TRUE` streams
chunks into the existing tiled GeoTIFF writer at a temp path, then
finalises with one `gdalraster::translate(of = "COG")` pass to the
requested path (translate is already used by the adapter,
R/gdal_adapter.R). Memory-bounded streaming is unchanged; the cost is
one sequential re-read/re-write of the finished raster plus overview
build, the trade every COG producer makes.

Details to settle at implementation:
- Overview resampling: expose it (nearest for categorical outputs
  like masks, average otherwise); do not silently reuse the read-side
  band resampling, which answers a different question.
- Compression: COG driver defaults to LZW; probably accept a
  `creation_options` passthrough rather than growing named args.
- Multi-export `path =` form: flag applies per sink; a named-list
  variant mirroring `band_names` if mixed outputs are ever wanted.
- Failure cleanup: temp GeoTIFF must be removed on translate error;
  the requested path must never hold a half-written COG.

## 8. collect() / write_tif() split: type-stable sinks -- DONE 2026-08-07

Decided (Hugh): split execution verbs by sink instead of ballooning
collect() arguments. NEXT UP after #9, together with #6.

- `collect(x)`: execute, return the (y, x, band) array with its gis
  attribute. Always an array: the current path= form makes the return
  type depend on an optional argument. Multi-export
  `collect(list(...))` unchanged.
- `write_tif(x, path, dtype, scale, offset, nodata, cog,
  creation_options, overview_resampling)`: execute, stream to GeoTIFF,
  return the path invisibly. Later siblings (`write_zarr()`) follow
  the same pattern. Naming settled: write_* (exit verbs, alongside
  materialise()), not collect_*.
- `materialise(x)`: unchanged; checkpoint to local cubes, stay lazy.

dtype/scale/offset is the payoff: write int16 reflectance with
scale/offset in band metadata; half the raw bytes of f32 and far
better compression (quantized ints vs float mantissas). Writer
applies round((v - offset) / scale) + cast per chunk at the sink
boundary; no graph changes; GDAL consumers (and #6's unscale) recover
physical values automatically. This is the exact inverse of #6, so
land them together and share the affine conventions.

Traps / details:
- NaN -> integer nodata sentinel chosen OUTSIDE the valid quantized
  range, mapped before scale metadata makes it ambiguous (reverse of
  the #6 sentinel-before-scaling rule).
- Rounding mode: document round-half-even vs round-half-up; pick one
  and test against gdal_translate -ot Int16 -a_scale behaviour.
- cog = TRUE from #7 lands here (stream to temp tiled GeoTIFF, then
  gdalraster::translate(of = "COG")).
- Multi-export file writes become `write_tif(list(...), paths)` when
  wanted; Plan@sinks is already sink-shaped.
- Soft-deprecate `collect(path=)` for one release (warning + forward
  to write_tif); update README + stac-composite + OCM vignettes.

## 9. Dependency placement + test-suite speed (2026-08-08) -- DONE 2026-08-07 (see resolution below)

Prioritised by Hugh ahead of #6/#8. Two coupled problems.

**(a) Dependencies live in the wrong tier.** anvl, mirai, mori,
cptkirk (and vaster) sit in Suggests but are fundamental: anvl is the
compute engine (135 skip guards across 79 test files), mirai the
daemon layer (44/39), cptkirk the warp reader, vaster the grid math.
They are Suggests only because they are GitHub-only and CRAN forbids
non-CRAN Imports; garry is not on CRAN, so Imports + Remotes is
available today. Move the engine tier to Imports, delete the guard
boilerplate, and let install-time fail fast instead of run-time
skip-storms. Revisit tiers only if CRAN submission becomes real
(then: vendoring/AdditionalRepositories decision, not a silent
downgrade back to Suggests).

**(b) Suggests-driven golden tests slow the suite.** The heavyweight
packages that remain legitimately optional are reference
implementations for golden tests: KFAS (kalman, 1 file), torch
(conv/OCM blocks, 4), terra (comparisons, 8), rustyfilters (2).
Running the reference implementation on every suite run buys nothing
after the first pass. Direction: freeze references into checked-in
fixtures (the ocm golden-fixture pattern: generate once offline with
the reference, commit values + generator script, assert against the
fixture); keep live-reference runs behind an env gate
(GARRY_GOLDEN=1) for regeneration and nightly CI. Reference packages
then leave Suggests entirely or stay for the gated path only.

Plan of attack:
1. Audit: per-test-file timings (testthat reporter) to rank cost;
   classify every Suggests entry engine / reference / STAC / infra.
2. Move engine tier (anvl, mirai, mori, cptkirk, vaster) to Imports +
   Remotes; strip skip_if_not_installed guards for them; full suite +
   R CMD check.
3. Fixture-ise KFAS/torch/terra/rustyfilters goldens (generator
   scripts in tools/, fixtures under tests/testthat/fixtures/);
   env-gate the live comparisons.
4. Measure suite wall-clock before/after; consider testthat parallel
   (test files are daemon-heavy, so check pool contention first).
5. CI: default runners run fixture suite; one job (or nightly) runs
   GARRY_GOLDEN=1 with the reference packages installed.

Traps:
- torch on CI has no Lantern -> torch_is_installed() gates stay for
  the gated path (see R-CMD-check history).
- Daemon-spawning tests must not run concurrently with each other
  (pool contention false failures); parallelisation needs a
  daemon-test serial group.
- terra's CRAN binary links system GDAL sonames (pkgdown ?ignore
  history); fixtures remove it from default CI entirely, which also
  kills that failure class.

### 9 resolution (2026-08-07, branch deps-test-speed)

Placement DONE as planned, with two corrections found in audit:
vaster is reference-tier, not engine (as_vaster_extent() is a pure
reorder; vaster's only use is 4 cross-check assertions in
test-grid-convention.R) so it stays in Suggests; rustyfilters was
UNDECLARED despite test usage, now Suggests + Remotes with
rustyfilters=?ignore on CI (cargo build, fragile on the Windows
runner toolchain). anvl/cptkirk/mirai/mori moved to Imports; 194
skip guards + 4 dead runtime guards stripped.

Speed: the golden-test hypothesis did NOT survive measurement.
Baseline (ListReporter, full local suite): 667 s test time / 11.2 min
wall; ALL reference tests combined (KFAS 11.4 s, terra files 16 s
whole-file, torch ~2.8 s, vaster/rustyfilters negligible) = ~30 s =
4.5% of the suite. Fixture-ising them was dropped: it buys no
meaningful time and the dependency-hygiene goal was met by
declaration + CI ignore instead. The real costs are engine suites:
grad-convergence 105 s (fixed: early-exit once assertions hold,
-> 58 s), routed-dispatch 51 s, route-matrix 32 s,
mirai-equivalence 24 s, gd-general 25 s (equivalence sweeps that
earn their time). After: 591 s / 9.9 min, 0 failures, identical
6984 passes.

TAKEN after Hugh pushed back on 9.9 min: testthat parallel. The
daemon-contention trap was tested empirically and does NOT apply at
test-pool scale (2-3 daemons per file; the original incident was a
benchmark-sized pool concurrent with the suite). Config/testthat/
parallel: true + start-first for the slow files. Measured on the
20-core dev machine, all runs 0 failures / identical 6984 passes:
4 workers 3.5 min, 8 workers 2.34 and 2.68 min (two runs). Local:
set TESTTHAT_CPUS=8 in user .Renviron (NOT the repo: CI checkouts
would inherit it). CI: testthat defaults to 2 workers under R CMD
check; watch the first macOS run. Caveat: each worker budgets
memory admission against system-available RAM independently, so
worker counts well beyond 8 overcommit admission.

Remaining lever, deliberately NOT taken (own pass if wanted):
- Shared file-level pools: ~50 local_pools() spawn/teardown cycles;
  a per-file pool fixture would cut per-worker time but some tests
  kill/rebuild pools mid-test and need isolation. Less pressing now
  that workers overlap the spawn latency.

### 6+7+8 resolution (2026-08-07, branch scale-and-write-tif)

All three shipped. Deviations from the spec, all Hugh's calls:
- #6 argument named `scale` (default FALSE), not `unscale`; TIFF/GDAL
  band metadata is the ONLY discovery source (no STAC raster:bands
  fallback: garry reads what QGIS reads; earth-search S2 users apply
  the arithmetic explicitly). Empirical probe matrix recorded in the
  session: MPC S2 = no metadata anywhere; HLS = TIFF tags; e84 S2 =
  STAC only (deliberately unsupported).
- #8 with NO deprecation shim: pre-release, so collect() lost
  path/nodata/band_names outright. Tests/benchmarks converted;
  .collect_impl (internal engine) keeps the full surface for
  write_tif()/materialise()/groups, including .vrt raw-cube sinks.
- Read affine applies in the read kernel AFTER sentinel->NaN (never
  as IR), so graph shape is unchanged and composite_direct stays
  eligible (affine rides the job, applied to the DN cube on device;
  heterogeneous per-slice affines fall through to the scheduler).
  Bonus discovered in mapping: the manual `(ds*s)+o` idiom DISABLES
  the composite_direct fast path (per-slice MapNodes break the
  2-parent masked shape); scale=TRUE does not.
- Write quantization at the single gdal_write_window choke point
  covers all five routes; sentinel maps AFTER quantization (DN
  units). round() is R round-half-even, documented.
- Roundtrip test: write_tif(dtype=i16, scale, offset) read back via
  lazy_source(scale=TRUE) is exact to scale/2. stac-composite writes
  the geomedian at 3.6 MB int16 vs 8.3 MB f32.

WATCH: one non-reproducible 8-worker suite hang (write-tif +
writer-errors area, log silent 33 min, all daemons idle) during this
work; two subsequent full runs green. If it recurs, suspect the
writer-daemon dispatch under concurrent pools; a stall detector
pattern (log mtime vs 120 s) is in the session scratchpad.

## 10. write_zarr(): Zarr output via the GDAL driver (2026-08-07)

Proposal (Hugh): a write_zarr() sibling of write_tif(). Decision:
sits behind the GDAL Zarr driver, NOT a new dependency (pixarr/Rarr
etc. stay out). Probed 2026-08-07 on GDAL 3.13/gdalraster: classic
Create + windowed band writes + readback all work, full dtype set --
so the entire write_tif machinery (wspec quantization at
gdal_write_window, streamed chunk writes, multi-export) reuses with a
driver switch at gdal_create_output.

Gating: garry's floor is already GDAL >= 3.9 (GTI driver), above the
Zarr driver's 3.4 (V2) / 3.8 (V3 spec-final) landings, so no NEW
version gate -- but builds can omit the driver, so gate at runtime on
gdal_formats("Zarr") with a clear error.

Details to settle at implementation:
- FORMAT=ZARR_V2 vs ZARR_V3 creation option: default V2 (widest
  ecosystem read support: xarray/zarr-python/dask) with a format arg.
- Chunking via BLOCKSIZE creation option; align to garry's chunk grid
  so streamed writes are whole-chunk (no read-modify-write).
- Compression codecs are build-dependent (BLOSC/ZSTD optional):
  probe, default to what exists, expose via creation_options.
- v1 scope: the write_tif raster model ((y, x, band) via classic
  API). A labelled (t, y, x) cube -- the real Zarr appeal -- needs
  GDAL's multidim API; check gdalraster coverage before promising it,
  else it waits.
- quantization/scale metadata: Zarr driver stores scale/offset as
  attributes? verify SetScale round-trips through the driver; if not,
  write _ARRAY_ATTRIBUTES/CF-style attrs explicitly.

## 11. Composite pipeline post-fetch tail (2026-08-08) -- DONE 2026-08-08

Observed on the README-scale HLS composite (Hugh, re-knitting the
README): after the last fetch lands, 13-15 s of exposed work before
collect() returns, identical with and without read-scaling (so not a
scale-on-read regression). Instrumented breakdown: last-band median
drain ~13 s, upper (ndvi) kernel 0.5 s, plan/materialise wrap ~5 s.

Root causes (branch pipeline-tail):
1. Every band median RECOMPILED its kernel: `g_jit` inline in
   `.gd_compute_masked_band`/`.gd_compute_mask` builds a fresh pjrt
   dispatcher per call (anvl's jit cache is keyed on input shapes and
   lives INSIDE the JitFunction object; the function is never part of
   the key), and the object was discarded after one call. `.gd_warm`
   only woke the PJRT client (2x2 kernel).
2. The last band's median was one whole-grid job on one width-1
   daemon, dispatched only when the final fetch landed.

Resolution:
- `g_fill` op (ops.R, D9): device constants via `anvl::nv_fill`, no
  host buffer -- warm-up dummies.
- Content-addressed kernel cache: host ships a `ck` (hash of slimmed
  F/op/nan_rm/affine/masked/device; mask kernel: chain sig + halo +
  dims) and the daemon get-or-creates the JitFunction in
  `.daemon_cache` (`.gd_cached_jit`); `.gd_lean_fn` rebuilds one
  canonical closure for both the real task and the warm.
- Strip decomposition: band medians split into equal-height row
  strips (`.gd_strip_bounds`, <=2 shapes; `gd_strips` option, auto =
  one per compute daemon). Bins are headerless row-major f32 so a
  strip is a contiguous seek+read; the mask cube is materialised
  before any band runs so strips need no halo; reassembly is raw
  concatenation in y order -- byte-identical (test-gd-tail.R).
- Real warm: `.gd_warm_pipeline` broadcast per width-1 compute
  profile during the fetch window compiles each distinct ck at each
  strip height on `g_fill` dummies, so no post-drain strip pays a
  compile. This retires the phase 9b objection ("mirai cannot route
  tasks to specific daemons") -- width-1 profiles made routing exact.

Deliberately NOT done: no spill of strips onto idle read daemons
(keeps the lean-reader design; revisit if the residual tail ever
matters); the three single-process inline `g_jit` sites
(whole-grid lean / gd_general / upper kernel) stay inline; the
`.daemon_cache` >64 wholesale flush stays (separate item).

Measured (README-scale live run: 44 slices, 1480x2536, 4 bands +
ndvi, garry_daemons() auto pools, 6 strips/band): post-fetch tail
13.4 s -> 3.65 s, with 0 post-warm XLA compiles (every strip hit a
warmed kernel); pipeline compute sum 51.2 s fully overlapped with
the fetch window; total collect 67.7 s -> 48.5 s (fetch was also
~8 s faster on the after-run, so the tail delta is the honest
apples-to-apples number). Local fixture tests: strips == whole-band
byte-identical, repeat collect creates 0 new kernels.

Benchmark (Hugh, 2026-08-08, benchmarks/compare.sh, 3-band HLS
median B04/B03/B02, cpu): garry 22.05 s vs ODC 27.59 s -- 1.25x
faster. Previously parity-to-slightly-behind (~1.0-1.2x of ODC);
the closed drain is the differentiator.
