# Design note: `ScanNode` (an iterative axis node) for temporal recursions

Status: **implemented** (2026-07-16, branch `scan-node`; anvl `nv_scan` on
branch `nv-scan`). Motivating use case: a per-pixel robust
local-linear-trend Kalman smoother over an annual stack (the temporal smoother in
the `hutan` canopy-structure pipeline), which is currently the dominant
wall-to-wall cost and runs per-pixel on CPU via `KFAS`. Written 2026-07-16.
Recorded implementation decisions are in section 9.

## 1. Context: the missing IR shape

garry's IR has four value-transforming node shapes:

| Node | Axis effect | Cross-element dependency |
|---|---|---|
| `MapNode` | preserves all | none (elementwise) |
| `FocalNode` | preserves all | spatial window (halo) |
| `ReduceNode` | **collapses** the `over` axis | reduces the axis to a scalar |
| `WarpNode`/`StackNode` | regrids / concatenates | n/a |

None expresses a **scan**: preserve an axis while carrying state sequentially
along it. A Kalman filter is exactly that shape. Over the time axis it carries
`(level, slope, 2x2 covariance)` from year to year and emits a smoothed value
*per year*. It is not a `MapNode` (each year depends on the others), not a
`ReduceNode` (the output keeps the time axis), and not a `FocalNode` (the
dependency is along time, not a spatial window).

So a new node is required. `ScanNode` is the natural sibling of `ReduceNode`:
the same execution shape (a barrier over one axis, freely chunked and distributed
over the other axes), but the body is a scan that emits a same-length series
instead of collapsing to a scalar, and the output grid keeps the scanned axis.

The backend capability already exists. anvl exposes `nv_while()`
(`anvl/R/api.R:2340`), a carried-state while loop that lowers to StableHLO
`WhileOp` on PJRT and to the quickr pure-R oracle, and is tested on both. This
design composes that primitive with one new IR node; it does not need a new
backend capability.

## 2. Why while, batched over pixels (not associative scan, not per-pixel)

The recursion is a forward Kalman filter (sequential over `t`) plus a backward
RTS smoother (sequential over `t` reversed), wrapped in a small fixed-count
robust-reweighting outer loop. Each step is tiny: a 2-vector state, a 2x2
covariance, an analytic 2x2 inverse for the gain, one scalar observation with
per-year variance `sigma_obs^2 / qa_t`.

- **Not associative scan.** A Kalman can be written as an O(log T) associative
  scan (Sarkka 2021), but with `T` around 15 years that span reduction buys
  nothing.
- **Parallelism is across pixels, not time.** The win over `KFAS` is to advance a
  whole spatial chunk's pixels through *one* `nv_while` whose carry is batched
  `[n_pixels_in_chunk, ...]` arrays. One 15-step loop steps every pixel's state
  together; XLA vectorises it and a PJRT GPU runs the chunk in parallel. `KFAS`
  runs one pixel's loop at a time on CPU. That batch-over-pixels vectorisation is
  the prize, and it is orthogonal to the mirai distribution `hutan` already does.

## 3. IR contract

```r
ScanNode <- S7::new_class("ScanNode", parent = Node, properties = list(
  over      = S7::class_character,   # axis name to scan, e.g. "t" (single axis)
  direction = S7::class_character,   # "forward" | "backward" | "bidir"
  fn        = S7::class_list,        # length-1 list holding the scan body kernel
  dtype     = S7::class_character    # output dtype (defaults to parent's)
))
```

Grid: unlike `ReduceNode` (which drops the axis via `.reduce_grid`/D7), the
output grid is the parent grid **unchanged** for a length-preserving scan. The
`over` axis and its length survive.

Body kernel contract, mirroring the custom reducer (`passes.R:79`,
`node@fn[[1L]](pv[[1L]], margins)`): the body is an anvl kernel

```
fn(x, margin)  ->  y
```

where `x` is the parent's full traced array including the scanned axis, `margin`
is that axis's position (from `.dim_margins`), and `y` has the **same shape** as
`x` (the axis is preserved). Inside, the body uses `nv_while`/`nv_scan` (below) to
carry state along `margin` and accumulate the per-step outputs. Everything else
in the chunk (the spatial axes) is batched: the carry and outputs are arrays over
the non-scanned axes.

`direction = "bidir"` composes a forward scan and a reverse scan (the RTS
smoother reads the forward filter's stored state), so the body receives the
forward outputs and scans them backward. This is one node, two internal
`nv_while`s, not two IR nodes.

## 4. User-facing API

Mirror `reduce_over`, keeping the axis:

```r
scan_over(x, fn, over = "t", direction = "forward", dtype = NULL)
```

`fn` is written in the `g_*`/`nv_*` vocabulary and may call `nv_while`/`nv_scan`.
As with `reduce_over`, a `LazyDataset` method (`.ds_scan`) applies it per band.
The temporal smoother ships as a prebuilt `fn` factory, e.g.

```r
kalman_llt(sigma_lvl, sigma_slp, sigma_obs, qa = NULL, robust_iters = 2)
```

returning the body kernel; the caller does
`scan_over(dataset, kalman_llt(...), over = "t", direction = "bidir")`.

## 5. Execution and planner

`ScanNode` is a **barrier on the `over` axis**, identical in shape to
`ReduceNode`: the chunk grid must hold the full scanned axis per chunk, but is
free to tile the spatial axes. Concretely:

- Planner: treat `ScanNode` like `ReduceNode` in `is_barrier`/`required_halo`
  (barrier over `over`, zero spatial halo). It cannot fuse across the `over` axis,
  but it fuses *upstream* maps (decode, standardise) into the same stage that
  loads the scanned axis, and *downstream* maps consume its output.
- Executor: the body compiles with `g_jit` exactly as a stage fn (`executor.R:446`
  `g_jit(s@fn, ...)`), the `nv_while` inside becoming a StableHLO `WhileOp`. The
  stage runs per spatial chunk, distributed across the existing daemon pools.
- Output: the smoothed stack keeps `[t, y, x]`; write it band-per-year like any
  multi-band result.

No new distribution machinery: this rides `collect`'s existing chunk-over-space
plus per-stage jit, the same path `ReduceNode` uses.

## 6. anvl requirement: an output-accumulating scan wrapper

`nv_while` (`anvl/R/api.R:2340`) carries fixed-shape state:

```r
nv_while(init = list(...), cond = function(...) <bool>, body = function(...) list(...))
```

A Kalman needs to emit a length-`T` series, so the body must write each step's
output into a preallocated `[T, ...]` buffer via `dynamic_update_slice` and carry
the buffer plus the loop index. Two options:

1. **Add `nv_scan`/`nv_fori` to anvl** over `nv_while`: a thin wrapper that takes
   a step `body(carry, x_t) -> (carry, y_t)`, a length, and stacks the `y_t` into
   an output array (managing the index and `dynamic_update_slice`). Reusable well
   beyond Kalman (EWMA, IIR filters, cumulative custom ops). Recommended.
2. Do the index-writes by hand inside each garry scan body. Works, but every
   temporal recursion re-implements the buffer bookkeeping.

Recommend (1): it is a small, general addition and keeps garry scan bodies
readable. It is the only anvl-side work; the loop engine itself is done.

## 7. The Kalman body (what the `fn` computes)

Local-linear-trend state space (matching `hutan/R/smooth-stack.R:439`):

```
level_t = level_{t-1} + slope_{t-1} + w_lvl
slope_t = slope_{t-1}             + w_slp
y_t     = level_t + v_t,   Var(v_t) = sigma_obs^2 / qa_t
```

- **Forward filter**: `nv_scan` over `t`, carry `(x = [level, slope], P = 2x2)`.
  Predict (`x <- F x`, `P <- F P F' + Q`), then update with `y_t` when observed
  (analytic 2x2 gain; skip the update where `y_t` is NaN, gating via
  `g_is_nodata`/`g_ifelse`). Store filtered `(x, P)` per `t`.
- **Backward RTS smoother** (`direction = "bidir"`): `nv_scan` over `t` reversed,
  combining filtered and predicted states into the smoothed series.
- **Robust reweighting**: a fixed `robust_iters + 1` outer passes that inflate
  the level noise `Q` at outlier years (residual-driven, `smooth-stack.R:139`).
  Fixed count, so unroll it (an R `for` around the two scans) rather than a
  data-dependent outer `nv_while`.

Batched: `level`, `slope`, `P` entries, and the per-`t` outputs are all arrays
over the chunk's spatial pixels; one scan advances them together.

Stays in R (not garry): the hyperparameter MLE (Nelder-Mead on a ~5000-pixel
sample, `smooth-stack.R:194`) and the empirical-Bayes regime-inflation scalar
(`:365`). These are one-off, off-raster. Fit in R, pass
`(sigma_lvl, sigma_slp, sigma_obs, inflation)` in as scalar constants to the body.

## 8. Validation plan (the bulk of the effort)

The risk is numerical fidelity to `KFAS`, not capability.

1. **Oracle first.** Build the body so it runs under anvl's quickr pure-R oracle
   (no PJRT) and diff against `KFAS::KFS` on a few thousand real pixel series from
   a hutan tile: assert the smoothed mean and standard error match within a tight
   tolerance, NaN/gap patterns identical.
2. **Diffuse initialisation.** `KFAS` uses exact diffuse init for the LLT (level
   and slope start with infinite variance). Decide between the exact diffuse
   recursion and a large-variance approximation, and record the decision here.
   Test the approximation against `KFAS` on short and gappy series (where diffuse
   init matters most) before accepting it.
3. **Robust loop last.** Validate the plain filter+smoother to tolerance first,
   then add the robust reweighting and re-check against `KFAS`'s robust output.
4. **PJRT parity.** Confirm quickr and PJRT agree (garry already asserts
   oracle==PJRT elsewhere), then benchmark a chunk on CPU and GPU vs the current
   per-pixel `KFAS` + mirai path.

## 9. Open questions -- RESOLVED (implementation decisions)

- **Output accumulation shape.** `nv_scan` peels the first iteration to learn
  the out shapes, preallocates `[T, ...]` buffers with `nv_fill`, and writes
  each step via `dynamic_update_slice` inside one `nv_while`; no growing
  concatenation. Reverse scans read and write at the original positions
  (`lax.scan` semantics).
- **Diffuse init (8.2).** Big-kappa (`P1 = 1e7 * I`, f64 body) accepted; the
  exact-diffuse fallback was NOT needed. Two findings along the way:
  (a) f64 is mandatory -- anvl materialises R double literals as f32
  constants, so all body constants inject via `nv_scalar_like`;
  (b) the textbook RTS forms `J = P_f F' S^-1`,
  `P_s = P_f + J (P_s_next - S) J'` lose ~6e-2 of the smoothed sd to
  kappa^2-scale cancellation before a pixel's second observation.
  Substituting `S = F P_f F' + Q` gives the exact, cancellation-free
  equivalents `J = F^-1 (I - Q S^-1)` and
  `P_s = F^-1 (Q - Q S^-1 Q) F^-1' + J P_s_next J'`; with those the KFAS
  diff is ~1e-7 on dense, gappy, and minimal (3-obs) series (gate: 1e-5).
  One KFAS convention to respect: `Q[,,t]` drives the transition t -> t+1,
  so a time-varying (robust) Q enters the predict into year t shifted by
  one (`Q_scale(t-1)`).
- **`bidir` contract.** One fused body (two `g_scan`s inside one kernel);
  forward state never crosses a node boundary. The backward pass consumes the
  forward outputs paired with their own shift (`g_slice_t(x, 2, T)`).
- **General reuse.** Kept general: `scan_over(x, fn, over, direction, dtype)`
  takes any body `fn(xs, margin)`; multi-input scans read several cubes in
  lockstep; `kalman_llt()` is just a prebuilt body factory (as `band_project`
  is for reduce). Robust reweighting runs as `robust_iters` unrolled passes
  around the fused smoother; hutan's per-pixel early exit needs no batched
  equivalent because the update is a pure function of the previous
  `Q_scale`, so converged pixels recompute bit-identical results.
- **Executor.** As designed: `ScanNode` is a barrier over `over` with zero
  halo, riding the ordinary compute-stage `g_jit` path; the gdal-direct
  whitelist excludes it (automatic scheduler fallback). The kernel-cache
  signature includes the body fn (the ReduceNode custom-fn omission was fixed
  in passing). Custom reducer/scan bodies are NOT `.slim_fn`-slimmed:
  factory bodies resolve garry internals through their namespace-parented
  environment, which serializes by reference.

## 10. Sequencing

1. anvl: `nv_scan`/`nv_fori` output-accumulation wrapper over `nv_while`.
2. garry: `ScanNode` IR + `scan_over()` + planner/executor wiring, modelled on
   `ReduceNode` (barrier over `over`, chunk over space, jitted body). Prove it on
   a trivial scan (e.g. cumulative sum via a custom body) against
   `reduce_over`/oracle.
3. garry: `kalman_llt()` body (plain filter+RTS), validated against `KFAS` under
   the oracle.
4. garry: robust reweighting, then PJRT + GPU benchmark vs the `KFAS`/mirai path.
</content>
