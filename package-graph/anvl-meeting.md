# garry x anvl: meeting notes

Curated companion to the generated [anvl-surface.md](anvl-surface.md)
(regenerate that with `Rscript package-graph/build_graph.R`; this file is
hand-maintained). Prepared 2026-08-17 for the discussion with Seb.

## The contract in one paragraph

garry's dependency on anvl is 37 functions, all called from one file
(`R/ops.R`), enforced by `tests/testthat/test-backend-insulation.R`. Every
op has a pure-R implementation alongside the traced anvl path, and
`test-ops-anvl-parity.R` requires the two to agree on NaN-bearing inputs to
f32 tolerance. The practical consequence for anvl: if a change breaks
garry, garry's test suite says so mechanically and localises it to a named
function and a named semantic. The surface below is what we need kept
stable.

## Why the g_* wrapping (anticipated question)

The wrappers are no longer about anvl being optional; anvl is a hard
import. They earn their keep three ways:

1. **Adaptation point.** Every impedance mismatch lives in ops.R: unsigned
   dtypes upload through signed carriers, raw-payload support is
   feature-detected by probing behaviour (not versions), scalar promotion,
   the jit bridge. An anvl API change touches one file.
2. **Conformance oracle.** The pure-R branch in each op is the executable
   spec of the semantics garry relies on. Same function, two paths,
   compared by the parity suite; the oracle cannot drift away from the
   thing it checks. It also lets planner and pass tests run where the XLA
   runtime cannot initialise (currently relevant on macOS CI).
3. **Zero runtime cost.** Ops execute only while anvl traces a closure for
   compilation, so the dispatch branch runs once per trace, never per
   pixel. There is no fallback execution path in production (one-compute-
   path rule, ops.R header).

## The surface, grouped (37 functions)

Full per-function caller table in [anvl-surface.md](anvl-surface.md).

- **Construction and transport**: `nv_array` (including raw byte payloads,
  see fork patches), `as_array`, `as_raw`, `nv_scalar_like`, `nv_fill`,
  `nv_convert`, `shape`, `dtype`. This is the hot path: one memcpy per
  chunk upload, raw f32 download on the other side.
- **Shape and layout**: `nv_reshape`, `nv_squeeze`, `nv_unsqueeze`,
  `nv_broadcast_to`, `nv_broadcast_arrays`, `nv_transpose`, `nv_pad`,
  `nv_static_slice`, `nv_concatenate`.
- **Elementwise and logic**: arithmetic via tracer dispatch, plus
  `nv_ifelse`, `nv_clamp`, `nv_round`, `nv_erf`, `nv_is_nan`, `nv_not`,
  `nv_and`, `nv_or`, `nv_xor`, `nv_shift_left`, `nv_shift_right_logical`.
- **Reductions**: `nv_reduce_sum`, `nv_reduce_min`, `nv_reduce_max`,
  `nv_mean`, `nv_median` (quantile fast path matters here, see fork
  patches).
- **Structured compute**: `nv_conv2d` (focal kernels), `nv_scan` (Kalman
  and Hampel smoothers, any iterative axis op).
- **Compile and differentiate**: `jit`, `value_and_gradient`.

## Semantics we depend on (the parity suite checks these)

- nodata is NaN throughout; `nan_rm` reductions skip it.
- All-NaN slice identities under `nan_rm`: sum is 0, min/max are +/-Inf,
  mean/median are NaN, count is 0.
- Integer cast truncates toward zero (XLA convert semantics); NaN cells in
  int casts are accepted as undefined.
- f32 is the working dtype; parity holds to 1e-5.

## Fork patches we currently run on (`belian-earth/anvl@nv-scan`)

Three substantive commits beyond upstream main, all upstreaming
candidates:

1. **`nv_scan`**: an output-accumulating loop built over `nv_while`. This
   is the pinned-branch reason; garry hard-errors without it when a plan
   contains a ScanNode.
2. **Raw byte payloads in `nv_array`** (paired with a pjrt patch,
   `raw-upload-dataptr-ro`): upload row-major f32 bytes with one memcpy,
   no R-double round trip, no relayout. garry probes for this at runtime
   and falls back to numeric upload, so upstreaming is additive.
3. **Selection fast path for low-probability quantiles**: `nv_median`
   performance on composite workloads.

## Workarounds in garry that are really anvl feature requests

- **Unsigned array construction**: anvl cannot build u8/u16/u32/u64 arrays
  from R numerics, so garry uploads QA bands through wider signed carriers
  (i16/i32/i64/f64). Noted in ops.R as a candidate upstream contribution.
- **`.g_has_raw_upload` probes behaviour, not versions**, because the
  patched branch shares upstream's version string. A capability flag or
  version bump policy would remove the probe.

## Implicit behaviour we lean on (worth making contractual)

- **The jit cache is garry's kernel cache.** anvl's shape/dtype-keyed LRU
  on each JitFunction is load-bearing: a regular chunk grid yields at most
  4 shapes per stage, so each stage compiles at most 4 executables
  (executor.R header). Cache eviction policy or key changes would silently
  change garry's compile behaviour.
- **The dispatcher cache hangs off the JitFunction object**, keyed on
  input shapes only. garry therefore content-addresses and reuses
  JitFunction objects across daemon tasks (`.gd_cached_jit`, daemon.R);
  an inline `jit()` per task recompiles every time. If anvl ever offered a
  process-level keyed cache, garry's daemon-side cache could shrink or
  disappear.
- **Device strings**: garry treats `"cpu"` as "anvl's default device" and
  passes `device` through `jit()` and `nv_array()` otherwise.

## Known gaps (our asks, roughly in priority order)

1. **Reverse rule for the scan/while loop.** Scans on the gradient tape
   are unsupported today (gradient.R refuses them); a reverse rule for
   `nv_scan` unlocks differentiable smoothers.
2. **Upstream the fork patches** (nv_scan, raw payloads + pjrt pair,
   quantile fast path) so garry can pin upstream releases again.
3. **Unsigned dtype construction from R numerics** (removes the carrier
   hack).
4. **Cache contract**: document (or stabilise) the JitFunction shape-LRU
   and dispatcher-cache behaviour garry depends on.

## What garry does NOT need

Autodiff beyond `value_and_gradient` on scalar losses; dynamic shapes
(chunk grids are static, at most 4 shapes per stage); sparse; complex
dtypes; distribution primitives (garry distributes with mirai above anvl).
