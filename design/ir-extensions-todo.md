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
