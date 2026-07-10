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
