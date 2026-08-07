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
STAC metadata but present in the TIFF). NEXT UP (2026-08-08, with
#8): an explicit `unscale = TRUE` on lazy_source() /
lazy_dataset() that reads GetScale/GetOffset at discovery (the D8
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

## 8. collect() / write_tif() split: type-stable sinks (2026-08-08)

Decided (Hugh): split execution verbs by sink instead of ballooning
collect() arguments. NEXT UP together with #6.

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
