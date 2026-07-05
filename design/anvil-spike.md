# Phase 0.5 spike: anvil (anvl) capability findings

Date: 2026-07-04. Scripts: `design/spike/01`-`08`, all passing on this
machine (Linux x86_64, R 4.6.0, NVIDIA RTX A1000, CUDA PJRT plugin).

## Verdict: GO

anvl expresses everything the IR needs. The Phase 6 exit criterion
(recover a 3x3 convolution kernel by gradient descent through a stencil
pipeline) already passes. No architectural assumption in
`design/lazy-raster.md` was invalidated; several were sharpened (below).

## Ground truth about the backend

- The package is **`anvl`**, not `anvil` (repo r-xla/anvil redirects).
  v0.3.0, MIT, not on CRAN; distributed via r-xla.r-universe.dev.
  Maintainer Sebastian Fischer; Posit-adjacent (Falbel, Kalinowski);
  MaRDI-funded. Young: one dominant author, 44 open issues.
- Stack: `anvl` (tracer, jit, AD) → `stablehlo` (R-native StableHLO IR)
  → `pjrt` (PJRT plugins, downloaded on demand: CPU 61 MB, CUDA 205 MB +
  `cuda12.8` runtime package from mlverse r-universe).
- `jit(f, static=, backend=, device=, cache_size=100)`: traces per
  (shape, dtype) signature into an LRU executable cache. Exactly the
  kernel-cache semantics the design doc assumed; we may not need our own.
- **Plain R operators trace.** `function(nir, red) (nir - red) / (nir + red)`
  and base `sum`/`mean` work on traced values. The MapNode expression
  surface is ordinary R arithmetic plus the ~160 `nv_*` ops.
- A second CPU backend exists (`backend = "quickr"`, Fortran via quickr).
  Platform matrix: Linux x86_64 CPU+CUDA; macOS ARM CPU only ("Metal
  partially functional"); Windows via WSL2. Drop Metal from near-term scope.

## Checklist results

1. **Composed map+reduce in one `jit()`** (01): passes, f32-exact vs R.
2. **Focal/stencil** (02): no convolution or `reduce_window` is exposed
   (`stablehlo` has `hlo_reduce_window` internally but unexported). The
   pad + (2h+1)^2 shifted `nv_static_slice` + weighted-sum pattern works,
   XLA fuses it: 3x3 mean on 2048^2 runs 59 ms/call including transfers
   vs 135 ms vectorised base R. Verified for mean, Sobel, h = 2.
   `nv_static_slice` is 1-based, inclusive limits.
3. **Integer/bitwise QA decoding** (03): full set (`nv_and/or/xor/not`,
   three shifts, `nv_popcnt`, `nv_bitcast_convert`, i8-i64/u8-u64) —
   bit-exact vs `bitwAnd`/`bitwShiftR`.
4. **Nodata** (04): **NaN-sentinel model adopted.** Reductions take
   `nan_rm = TRUE` (`nv_reduce_sum`, `nv_mean`, `nv_median`,
   `nv_quantile`, ...) and match R's `na.rm = TRUE` to f32 precision,
   including all-nodata cells (anvl yields NaN where R yields NA; same
   meaning). Valid-obs count = `reduce_sum(convert(!is_nan(x)))`, exact.
   Integer bands: sentinel compare + `nv_ifelse` promoting to f32 NaN.
5. **Gradient** (05): `gradient()` / `value_and_gradient()` (returns
   `list(value, grad$<arg>)`) validated against finite differences to 5
   decimals; kernel recovery converges to <1e-5 in 300 steps (lr 0.2).
6. **Transfer costs** (06): ingress ~1-2 GB/s, egress ~0.4-1 GB/s (f32
   egress is half of f64: R doubles force a conversion). Cached-kernel
   dispatch ~410 us/call. **Consequence: fusion is load-bearing, not an
   optimisation.** A bare NDVI map on 1024^2 is 15.5 ms via jit vs 3.6 ms
   in base R (transfers dominate); the fused focal chain wins 2.3x.
   Per-op eager execution would lose to base R everywhere.
7. **Shape recompilation** (07): ~30-60 ms compile per novel shape,
   2-11 ms cached. A regular chunk grid yields at most 4 shapes
   (interior, right edge, bottom edge, corner), so ragged edge chunks
   are fine as-is: **no pad-to-uniform needed.** Answers the open
   question in the design doc.
8. **Devices + mirai** (08): CUDA jit round-trip works
   (`device = "cuda"`). On this laptop GPU ~= CPU for a bare map (PCIe
   dominates); GPU pays off only for fused compute-heavy stages. mirai
   daemon compiles and runs kernels and returns R matrices: the
   chunk-task shape of the executor works today.

## Design implications

- **`focal()` must take an explicit `radius`** (footprint cannot be
  inferred from an arbitrary R function). The planner expands it to the
  shift-and-combine pattern; a `stencil()`/`focal_kernel()` helper wraps
  the boilerplate. Consider contributing `nv_reduce_window` upstream
  later; not a blocker.
- **Executor must keep intermediates device-side within a stage** and
  convert to R arrays only at stage boundaries (halo store, sink).
  Chunk sizes should be >= ~1 MP so 410 us dispatch stays negligible.
- **Differentiable focal-median is out of scope** (XLA limit: no custom
  window monoids in AD). Differentiable pipelines also stop at Warp
  barriers (GDAL is outside the tape). Document both.
- **GPU daemon pools**: one process per GPU (or NVIDIA MPS) — N workers
  sharing one GPU serialize and burn ~300-500 MB GPU RAM each. XLA
  preallocates by default; cap it for multi-daemon hosts.
- DESCRIPTION fixed: `Imports: anvl`, `Remotes: r-xla/anvl` (plus
  transitively tengen/xlamisc/stablehlo/pjrt via r-universe).

## Backend alternatives (separate research, 2026-07-04)

Conclusion: anvil-first stands. anvl is the only candidate where JIT
fusion, tracing, reverse-mode AD, CPU+CUDA, raster-shaped ops, and
zero R wrapping cost all hold today. Hedges, in order:

1. **torch for R** — maturity hedge (6 years on CRAN, best AD). Fails on
   fusion: GPU pointwise only via deprecated TorchScript, no CPU fusion
   ever; 3.8 GB CUDA runtime per worker. Worth a benchmark: if eager
   torch is within 2x of fused anvl on our pipelines, maturity argues.
2. **burn + CubeCL (Rust)** — architecture hedge (lazy fusion streams,
   AD, small binaries, ROCm/Metal/Vulkan portability). Costs: greenfield
   savvy/extendr binding, quarterly breaking changes, no stencil fusion.
3. **Halide** — technically ideal for stencil fusion (and has AD) but
   means writing an R tracer + Rcpp glue + schedules + LLVM-sized
   binary. Possible specialist backend later, not a foundation.
   ArrayFire (no AD), Futhark (AOT shape), candle (no fusion/bitwise),
   TVM/IREE-direct (wrong layer) are excluded.

Insulation policy: garry's IR composes functions over a **garry-owned op
vocabulary** (thin wrappers over `nv_*`). Users write plain arithmetic;
named ops route through our layer, keeping a future backend swap or a
torch benchmark harness cheap.

## Residual risks

- anvl API stability pre-1.0 (rename anvil→anvl already happened once).
  Pin exact commits in Remotes until releases stabilise.
- AnvilArray allocator behaviour under high chunk throughput untested
  (design doc open question stands; test in Phase 5 with allocation
  storms).
- `gradient()` through `nan_rm` reductions untested; verify before
  Phase 6 (NaN + AD is a classic poison combination).
