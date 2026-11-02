# Kernels as programs, and one program per chunk

Status: 2026-10-31, branch `stablehlo-kernels`. The defaults are `kernel_wire = "program"` and `stage_merge = "auto"`, with `"closure"` and `"guarded"` kept as rollback switches until a production run. Whole-chunk merging (`stage_merge = "chunk"`) and `garry.pad_to_chunk` were tried and removed; their results stay in section 6 as the record. Section 7 records what the review of this branch changed.

## 1. The problem

Stage kernels cross processes as R closures. A daemon unserialises the closure, traces it through anvl, lowers it to StableHLO and compiles it. Three costs follow.

- **A closure carries what it can reach.** hutan's growth-cap scan body reached the graph, then `si_tail()`'s frame, then through `do.call()`'s unforced promises the whole of `si_build()`'s frame: 13 to 34 GB per compute daemon per run, on the largest jobs about a sixth of the wall (see the index audit). `.slim_fn` is a fence against this class, and a leaky one: it cannot see into captured closures, `get()` or classed objects.
- **Every daemon repeats the trace.** On the tail plan about three quarters of a kernel's preparation is R tracing and lowering, and only a quarter is XLA.
- **Identity needs a parallel system.** `.fn_identity` hashes closures, captured bindings and all, because a closure has no stable content of its own, and every factory must stay "slim-safe".

Separately, a tail plan cuts one chunk into 87 compute stages running 9 distinct kernels. Each stage's output passes through the store and each task through the host loop, so the host sweep, the store gate and the drop path all scale with stage count.

garry's scope makes both avoidable. Kernels are a closed vocabulary, "no arbitrary R, ever", so every kernel lowers to StableHLO, and StableHLO exists to be a portable program between a frontend and a compiler. anvl's `jit()` already goes through MLIR text on the way to `pjrt_compile()`.

## 2. Kernels as programs

`garry.kernel_wire = "program"`:

1. The host traces each kernel once per input shape set, with `anvl::trace_fn(optimize = TRUE)`, `anvl::stablehlo()` and `stablehlo::repr()`. The results are kept for the session, keyed by kernel signature and shapes, so later tiles of a shape trace nothing.
2. What crosses is a `garry_programs` set: shape key -> `list(src, constants)`. `constants` are closed-over arrays that lowering lifts to leading inputs. The set holds each once, as raw bytes in its `constants` attribute, and a program indexes them.
3. A daemon compiles with `pjrt_program(src, format = "mlir")` and `pjrt_compile()`, once per shape, inside a `pjrt::dispatcher()`: the same cache, buffer wrapping and phantom outputs as `jit()`, with the compile callback reading the program in place of tracing. A warm-up compiles the first shape, the modal chunk's; a task compiles any other it meets. Shapes share one device buffer per constant, and a compiled shape's text and an uploaded constant's bytes are dropped. The phantoms matter, because they are how R counts a CPU output's memory. `.kernel_of()` returns a function of a list of arrays either way, so task bodies are unchanged.
4. Warmth outlives a run, keyed by kernel and shape, and is dropped by `garry_daemons()`. A daemon that wiped its cache takes the existing `garry_jit_miss` path and gets the program resent.

Compute tasks and fused reads both use this. A stage's shape set comes from its chunk table: the modal chunk where edges grow to it, otherwise every distinct chunk shape, and each row-tile height for a tiled fused kernel.

**What remains.** Programs are the default, but closure shipping, `.slim_fn`, the closure half of `.fn_identity`, hutan's slim-safe rule, daemon-side tracing and `.daemon_warm_jit`'s dummy execution all stay while the paths in section 7 run closures. The untraced oracle stays regardless: it is the correctness reference and never crosses a process.

## 3. One program per chunk

After the guarded merge pass, `.merge_chunk_pipelines()` folds each connected group of spatially equal compute stages into one stage, where `.merge_worth()` says it pays (`stage_merge = "auto"`). `.compose_stage_fn()` needs no change, and a merged stage flows through both executors as any multi-export stage does. Chunks stay sized on the unmerged stages. A group a non-compute stage would both feed and read from stays split, because a spatial reduce's combine runs on the host.

The guards in `.merge_stages()` exist for reasons this spike must respect:

- **Kernel sharing.** Per-slice stages collapse to one kernel, which is what stopped the morphology compile storm. One big program gives that up.
- **Dependency frontier.** A merged stage waits on all of its inputs, where a split one starts early. Merging a per-year map once inflated a predict plan's tasks 18x through the sizing passes; the sizing part is handled above, the frontier is not.
- **Halo.** A merged stage puts the widest halo on every read.

So this has to be a cost-based decision per plan, not a blanket setting.

## 4. Open points

- **Compile time** per program, on a real worker's CPU, and how it scales with plan size.
- **Constants as inputs.** Would let metrics share a program, 14 down to 9 on split and 2 down to 1 on whole chunk, saving about 16 s per metric per shape on whole chunk and nothing measurable on split. Value-safe once the f32 print is fixed. Not worth building yet: see A second metric in section 6.
- **Narrow boxes.** Tested: see Padding in section 6. `.modal_chunk()` gives one shape for the kernels, the store estimates and `strip_rows`.
- **Buffer donation.** Tested and removed: no memory saving. See section 6.
- **anvl surface.** The spike calls `trace_fn()`, `stablehlo()`, `pjrt::dispatcher()` and `pjrt_compile()` from `R/ops.R`, the one file allowed to. A small exported pair in anvl, program out and program in, would be cleaner. The R package has no executable serialisation yet, so each daemon compiles.
- **Cache key.** A program's text is not its identity: captured arrays sit outside it, and default dtypes change what compiles. A text-hash key must include both.
- **Scan confinement.** A merged stage containing a scan runs only on the `scan_profiles` daemons.
- **Other devices.** Program mode is CPU only for now. CUDA keeps closures.

## 5. Rule check

Any default change must pass the general-improvement rule: A/B time and physical memory across workload shapes, not only correctness. That means the tail, predict, morphology, bilateral, OCM, wide pools, tight memory limits, mixed task sizes, the write route, and remote fetch once network allows.

## 6. Results

Measured 2026-10-30 on a 20-core workstation in an 8 GB scope unless stated, on local fixtures with no network. Another session's job shared the machine for parts of this, so treat small timing gaps as noise. Output values matched across arms on every fixture that completed. Peak memory is anon plus shmem sampled every 0.2 s, which is what an OOM kill counts.

**Kernels on the wire.** Sum over distinct kernels.

| Workload | Closures | Programs |
|---|---:|---:|
| Tail, 19 years, 3 arms (one program per kernel) | 113 MB | 0.9 MB |
| Morphology, 24 slices | 45.5 MB | 0.11 MB |
| OCM, regnety | 102.7 MB | 51.5 MB, weights as constants |
| Predict | 0.6 MB | 0.08 MB |

**Wall, cold then warm, seconds.** Single runs on the first version of program mode, without phantom outputs.

| Workload | Closures | Programs | Whole chunk |
|---|---:|---:|---:|
| Tail, 876 tasks | 38.6, 28.8 | 27.0, 18.8 | 41.0, 20.9 |
| Morphology | 4.6, 3.1 | 3.6, 1.8 | 7.9, 1.9 |
| OCM | 9.2, 5.2 | 6.3, 2.8 | 6.2, 2.5 |
| Bilateral | 3.4, 3.1 | 3.8, 3.1 | 3.9, 3.1 |
| Predict | 13.4, 13.9 | 14.1, 14.7 | 19.4, 18.2 |

**Tail at scale**, 3,225 tasks when split, on the final kernel path. Two tails per run in one pool.

| Pool, limit | Arm | Finished | Cold, warm s | Peak MB |
|---|---|---:|---:|---:|
| 2 compute, 8 GB | Closures | 1 of 2 | 65.3, 60.9 | 6,648 |
| | Programs | 2 of 2 | 59.5, 52.0 | 5,170 |
| | Programs, maps merged | 2 of 2 | 60.9, 52.0 | 5,160 |
| | Programs, whole chunk | 2 of 2 | 43.9, 16.3 | 5,950 |
| 6 compute, 7 GB | Closures | 0 of 2 | | |
| | Programs | 2 of 2 | 55.0, 51.0 | 6,545 |
| | Programs, maps merged | 1 of 2 | 50.9, 44.9 | 6,660 |
| | Programs, whole chunk | 2 of 2 | 62.7, 27.5 | 6,567 |

The failed arms were OOM kills. Two of them then hung until the test's timeout, which fits a dead daemon's task never resolving. That is the baseline's behaviour as well as this branch's: `.assert_pools_alive()` only runs at run start.

**Predict memory.** 21 runs per arm over three batches, order alternating in two. Mean peak by batch: closures 7,397, 7,501, 7,535 MB; programs 7,581, 7,814, 7,544 MB. Run-to-run spread is about 250 MB and the fixture sits at its limit. Programs lost 2 of 21 runs to the scope limit and closures none, which is too few to separate from chance. Any cost is about 2 % or less.

**Compile.** Whole-chunk tail program, 2.7 MB of text: trace 12.0 s, lower 4.8 s, repr 1.9 s, XLA 7 to 9 s. A fresh process with no plan, graph, closure or hutan compiled it and ran it bit-identically to the stage-wise pass.

**XLA options.** On that program:

| Option | XLA compile s | Run s | Values |
|---|---:|---:|---|
| Default | 7.2 to 7.5 | 0.91 to 1.07 | same |
| `xla_backend_optimization_level` 1 or 2 | 6.7 | 0.91 to 0.98 | same |
| `xla_backend_optimization_level` 0 | 6.3 | 2.11 to 2.27 | **differ, up to 0.0025** |
| `xla_llvm_disable_expensive_passes` | 6.8 | 0.91 to 0.97 | same |
| `xla_cpu_parallel_codegen_split_count` 1, 8, 64 | 7.3 to 7.7 | 0.98 to 1.14 | same |

None is worth having, and level 0 must never reach production. Compile time has to come down through tracing once, fewer distinct programs, and compiling once then loading the result: `PJRT_Executable_Serialize` is in the plugin's API, but it is not bound in {pjrt} and whether the CPU client implements it is unchecked.

**Where compile time goes.** The whole-chunk tail program is 21,758 traced statements and 63,199 lines. Tracing spends 30 % of its time in `nv_broadcast_scalars`, lowering 36 % in `hlo_broadcast_in_dim`, and 53 % of the 30,739 operations are duplicates: 7,580 constants hold 65 distinct values, and 7,526 broadcasts hold 100. Removing them from the text took it from 63,201 to 22,881 lines with identical values and left XLA at 7.3 s, so duplicates cost only R time, and fixing that is an anvl change.

The real driver is hutan's `.garry_interp_fn`, an R loop unrolled per knot. One 20-knot lookup is 413 statements, so 37 arm-years are about 70 % of the program: the JIT article's "R loops are unrolled". Written as `g_scan()` over the knots, on a scratch copy of hutan:

| Whole-chunk tail program | Text MB | Trace s | Lower s | Repr s | XLA s | Run per chunk s |
|---|---:|---:|---:|---:|---:|---:|
| Today's lookup | 2.72 | 12.0 | 4.8 | 1.9 | 7.3 | 1.06 to 1.20 |
| Lookup as a loop | 1.04 | 3.5 | 1.6 | 0.6 | 1.8 | 0.92 to 1.02 |

**The loop form is not bit-identical.** Two of four sinks differ, by up to 1.9e-6 relative, in 40 to 52 % of raw cells. On this noise fixture, 0.006 to 0.03 % of int16 cells change by one step at scale 0.01, and 0.06 to 0.3 % at 0.001. The cause is unknown. Products must not change without the maintainer's decision.

**Tail end to end, with both lookups.** Program mode, 8 GB, mean of two runs.

| Fixture | Lookup | Stages | Cold, warm s | Peak MB |
|---|---|---|---:|---:|
| 876 tasks split | Today's | Split | 28.6, 21.2 | 5,976 |
| | Today's | Whole chunk | 48.6, 20.1 | 6,494 |
| | Loop | Split | 28.0, 21.5 | 6,203 |
| | Loop | Whole chunk | 31.2, 18.5 | 5,512 |
| 3,225 tasks split | Today's | Split | 56.3, 47.1 | 5,230 |
| | Today's | Whole chunk | 38.5, 16.5 | 6,000 |
| | Loop | Split | 63.0, 54.5 | 5,352 |
| | Loop | Whole chunk | 21.9, 14.4 | 5,168 |

With the loop, whole chunk loses little or nothing cold and wins warm on both fixtures, and its memory premium goes. So program size, not merging as such, caused the compile and memory cost on this workload. Morphology and predict have no lookup, so their results above stand.

**Why the loop lookup differed.** Not arithmetic. stablehlo 0.5.0's `format_double()` formats an f32 constant from the R double, to 9 digits. Nine digits round-trip only when printed from the f32 value, so a double near the midpoint of two f32 values can land on the wrong one: about 1 % of random doubles do. In the fixture one knot of 20 is affected: 12.6315789474 should be 12.63157940 and parses as 12.63157845. Array constants and inputs pass through buffers and are rounded correctly. Upstream fixed this in #206 on 2026-10-12, unreleased: r-universe still serves 0.5.0. With stablehlo `main` (`d0f839ad`) every form agrees on every cell: unrolled, loop, scalars as inputs, one call per knot, each kind of constant lifted alone, on a linear and a curved map. Through the pools, the tail hashes `3c17d9e538` with both the unrolled and the loop lookup. Taking the fix moves today's products by the amounts above, only for literals that were mis-rounded, and it removes the only value risk seen in the loop and in constants as inputs. XLA's passes and FMA are not involved: disabling them leaves the difference unchanged at the same knot.

**Automatic merge rule.** `stage_merge = "auto"` folds a group of compute stages only when `.merge_worth()` says the task overhead it saves beats the compile it costs. It uses plan facts only: stages, chunks and members. One run per arm, program mode, loop lookup, 8 GB, cold and warm seconds. The rule folded both tails and left the other workloads split, which is the better arm on each, and hashes matched across arms.

| Workload | Split | Auto | Whole chunk |
|---|---:|---:|---:|
| Morphology | 3.4, 2.0 | 3.5, 2.2 | 8.4, 1.9 |
| Bilateral | 4.4, 3.3 | 3.9, 3.2 | 4.1, 3.2 |
| Predict | timed out | 16.7, 16.1 | 18.4, 16.4 |
| OCM | 6.2, 2.6 | 6.9, 2.8 | 6.8, 2.9 |
| Tail, 876 tasks | 35.2, 26.3 | 30.9, 23.6 | 30.2, 22.9 |
| Tail, 3,225 tasks | 68.3, 57.9 | 28.7, 17.3 | 26.0, 19.0 |

The timed-out predict run is the dead daemon hang of section 4, not a merge effect: its stages are the same as the auto arm's. The constants in `.merge_worth()` are coarse, calibrated on these workloads, and include the host sweep's quadratic term, so fixing the sweep changes them.

**A second metric.** The tail run again in one pool with its own calibration and variances, then the first metric repeated. Text census: every float constant replaced by a placeholder.

| Arm | Programs, metric 1 | New for metric 2 | Programs with scalars as inputs | Wall, first, new metric, repeat |
|---|---:|---:|---:|---:|
| Split | 9 | 5, 1.5 s trace | 9, against 14 | 38, 34, 36 s |
| Whole chunk | 1 | 1, 11 s trace | 1, against 2 | 44, 48, 32 s |

So a new metric costs whole chunk about 16 s per shape, which constants as inputs would remove; split barely notices. A repeated metric already costs nothing. Scalars alone were enough: arrays add no further sharing.

**Padding.** A grid narrower than a chunk has its own shape, so each box of an index job recompiles every kernel. `garry.pad_to_chunk` grows such chunks past the clipped shape, with the machinery edge chunks already use: `"full"` to the whole chunk, since dropped, and `"ladder"` to the next of the chunk's repeated halvings per axis, which bounds padding below 2x an axis. Eight boxes of mixed shape, 260 to 900 cells a side, one `si_tail()` each in one pool, on 512-cell chunks, split, loop lookup, six runs per arm. Spread between repeats is about 1 s. The first round pays compile, the second shows the bare cost of the padding. All 8 boxes hash identically in every arm, across 18 runs.

| Arm | First round | Second round | Host trace | Peak |
|---|---:|---:|---:|---:|
| Clipped, today | 81.9 s | 45.8 s | 24 s | 4,876 MB |
| Ladder | 56.2 s | 49.0 s | 3.4 s | 4,593 MB |
| Full | 55.4 s | 49.1 s | 3.3 s | 4,698 MB |

Padding saves 31 % when shapes are new and costs 7 % when they are not, with no extra memory. An index job meets a box once per metric, so it sits nearer the first round. Earlier batches gave a larger gain, but they ran on a contended machine, where unpadded arms took twice as long: only these 18 runs count.

On smaller boxes, 64 to 350 cells a side on the default chunk, two runs per arm on a quiet machine: clipped 66.3 and 35.8 s, ladder 62.8 and 28.8 s, full 59.5 and 33.7 s. Full padding was dropped: it never beat the ladder, and on this set it still traced 5 of 8 boxes, because the fixture's VRT crops have block sizes that vary with the box and the planner snaps chunks to blocks. Ladder beating clipped in the second round was the daemon cache, see below.

With `kernel_wire = "program"` and `pad_to_chunk = "ladder"` the suite ran 8,482 expectations: 2 failed, 0 errors, 3 skipped. `test-scan-strips.R` pins `strip_rows` to the clipped chunk, which padding changes on purpose. `test-fuse-wide.R` found the one way padding is not value-neutral: XLA takes a different code path for a dot on a small matrix. In direct tests, with 8 hidden units, rows up to 64 differ from the same rows of a larger dot, and rows from 256 up never do; with 64 hidden units none differ. A 300 x 300 raster MLP is identical in all padding modes. So this reaches only windows of a few dozen cells, which the fixture has and production chunks do not.

**Daemon cache.** A daemon held 64 kernels. Eight boxes at about 14 kernels each overflow that, so a pool revisiting them recompiled on every pass, and padded runs looked faster than clipped ones: compute task time for the same 696 tasks was 14.7 s clipped against 6.4 s ladder. At a cap of 512 the second round is 26.4 s clipped and 29.3 s ladder, the order padding predicts, and peak memory does not rise. Least-recently-used eviction at 64 changed nothing, as expected of a cyclic visit larger than the cache, so it was dropped. A compiled tail kernel holds about 2.2 MB beyond a one-off 100 MB for the compiler, so `.kernel_cache_max` is 256: at most about 560 MB per daemon, reached only by a run with that many kernels.

**Programs, auto and ladder against today.** The set first proposed: `kernel_wire = "program"`, `stage_merge = "auto"`, `pad_to_chunk = "ladder"`, against closures, guarded merging and no padding. Two runs per arm, 8 GB, cold and warm seconds, peak MB, stablehlo `main`, loop lookup. Every hash matches across arms.

| Workload | Today | Proposed |
|---|---:|---:|
| Tail, 3,225 tasks | 50.3, 47.0, 6,530 | 18.1, 12.0, 5,250 |
| Tail, 876 tasks | 30.0, 25.4, 7,640 | 20.4, 14.3, 5,590 |
| Morphology | 4.1, 2.7, 3,770 | 2.9, 1.8, 2,660 |
| OCM | 5.1, 2.8, 3,400 | 3.8, 1.6, 2,650 |
| Bilateral | 2.9, 2.7, 2,840 | 3.3, 2.6, 2,740 |
| Predict | 11.7, 10.9, 7,650 | 11.8, 10.7, 7,360 |

**Padding was removed.** At 10 GB the proposed set took predict to 16.5, 17.6 s and 9,240 MB against 8.8, 8.0 s and 5,250 MB. Tested alone, closures with the ladder gave 15.4, 17.9 s and 9,436 MB, while programs gave 8.8, 8.7 s and 5,032 MB and programs with `auto` 9.0, 8.8 s and 5,275 MB. With more memory the chunk outgrows the 1024-cell grid, so the ladder pads the grid up to the chunk, and an MLP pays for every cell. The 8 GB runs hid this: there the chunk is 768 cells and nothing pads. So padding helps where compile dominates and hurts where cells do, and the plan cannot tell which. Its only value was a many-box tail, and no caller asked for it, so the option went. The defaults are `kernel_wire = "program"` and `stage_merge = "auto"`.

**The defaults against today.** Programs and `auto` against closures and guarded merging, no padding. Two runs per arm, 10 GB, stablehlo `main`, loop lookup, cold and warm seconds and peak MB. Every hash matches across arms. The full suite on these defaults: 8,486 expectations, 0 failed, 0 errors, 3 skipped.

| Workload | Today | Defaults |
|---|---:|---:|
| Tail, 3,225 tasks | 34.6, 44.7, 7,117 | 18.1, 11.9, 5,360 |
| Tail, 876 tasks | 26.8, 21.6, 7,811 | 19.4, 13.1, 5,916 |
| Morphology | 7.0, 7.1, 5,402 | 2.5, 1.4, 2,810 |
| OCM | 5.0, 2.8, 3,409 | 3.8, 1.6, 2,648 |
| Bilateral | 3.5, 2.6, 2,863 | 3.5, 2.6, 2,758 |
| Predict | 9.6, 8.4, 5,092 | 8.9, 8.2, 5,269 |

**Predict at the cap.** Predict peaks near this fixture's 8 GB cap, so some program runs were OOM-killed: across every batch, programs 8 of 48, closures 0 of 31. Exit 143 in those runs is not a timeout or a hang: after a kernel kill in a scope, systemd stops the scope with SIGTERM. The plan is identical under `guarded`, `auto` and ladder, and by role the arms sit about 1.4 % apart at peak, with no role standing out. Treated as a small gap: the 2 to 4 % cost near a hard limit is accepted, and the design keeps a watch on it.

**Program identity.** An independent review of this branch found that programs gave silent wrong results, which the suite had missed because its workloads are nearly all f32. Reproduced through the pools: a u16 raster ran an f32 program of the same shape, because PJRT checks buffer size and not type, and returned wrong values; an i16 raster crashed; a kernel reading a global kept its old value after the global changed. Fixed at source, with no fallback, so nothing is retried down another path:

- The program key covers input dtypes, anvl's default dtypes, the values of globals a kernel reads, the contents of captured arrays, and scan labels.
- A daemon dispatches on exact dtypes and shapes. Anything else raises `garry_no_program_error`: PJRT would otherwise run it.
- The host knows every input before it traces. A node's declared dtype is the kernel's real one: `lazy_map()`, `scan_over()` and a custom `reduce_over()` trace `fn` on abstract inputs when the raster is built (`.node_dtype()`), and every member holds its declared dtype (`.g_as_declared()`), so a value does not depend on where a stage boundary falls and every executor and writer reads the same dtype from the graph. Outer dims come from the graph too: an input's grid dims, size-one axes included, flat only for a read whose dims multiply to one.
- A kernel that fails to trace is the task's failure, raised on the host as `garry_task_error`. It no longer stays a closure.
- The host memo drops its oldest sets past 1 GB, and warmth resets when daemon caches are emptied.
- A dead reader on the gdal-direct routes is a failed read, not a NaN slice, and those waits check liveness.

**A lost daemon.** A daemon killed mid-run hung the host on width-1 profiles and the writer, which have no dispatcher to hand a task back. `.assert_pools_alive()` already guarded the read-only route and run start; it now guards the scheduler's drain and writer waits and the gdal-direct waits, and cleanup no longer waits on a daemon that has gone. Killing each kind mid-run: compute and writer fail with `garry_pool_error` in 2.8 s, reader in 2.1 s and compute on the median route in 1.1 s with a readable task error, and teardown takes 0.8 s. A later run fails in 0.1 s on a dead compute profile, on a pool with no reader left, and on a dead writer if it writes: `garry_daemons_set()` says the pools were set, so such a run no longer moves onto the host.

**Donation.** Marking kernel inputs as donated changed no output hash and saved no memory, so the switch was removed. XLA reuses a donated buffer only for an output of the same type, not for temporaries, and most kernels have no such output. Three pairs per row, means of finished runs, program mode at 8 GB. Timing differences sit inside the spread between repeats, which reached 25 to 40 s for one tail arm.

| Workload | Off: finished, cold and warm s, peak MB | On: finished, cold and warm s, peak MB |
|---|---:|---:|
| Morphology | 3 of 3, 4.6, 2.8, 2,772 | 3 of 3, 3.8, 2.3, 2,783 |
| Predict | 2 of 3, 17.0, 17.0, 7,586 | 3 of 3, 15.9, 16.4, 7,858 |
| Tail, whole chunk | 3 of 3, 32.8, 22.6, 5,617 | 3 of 3, 32.2, 22.1, 5,597 |
| Tail, split | 3 of 3, 36.9, 26.8, 6,109 | 3 of 3, 34.9, 26.0, 6,046 |

**Tests.** Full garry suite, 8,482 expectations, 0 failed, 0 errors, 3 skipped, with `kernel_wire = "program"` and with the switches off. Whole chunk has not been run under the suite: golden plans pin stage counts.

**Reading.** Programs improve or match every workload measured, and they are the only arm besides whole chunk that survived 6 daemons at 7 GB, where closures did not. Whole chunk loses on small plans, where compile dominates, and on predict, where a merged stage waits for all its inputs. It wins strongly on large many-task plans once warm, 16 s against 52 s, and it costs about 15 % more peak memory there than programs do. Folding only the map stages gave nothing, which suggests the saving comes from the scan's inputs and outputs leaving the store, not from the tiny stages alone (inference). Whether to merge has to be a per-plan decision.

## 7. After review

Recorded 2026-10-31. The review of this branch changed these decisions, beyond the program identity rules in section 6.

- **Closures cross on two paths:** `kernel_wire = "closure"` and any device but the CPU. The daemon kernels of the composite and reduce routes (`.execute_composite_direct()`, `.execute_gd_reduce()`) are programs like any other, traced on the host at run start, and their specs carry no closure beside the set. The kernels those routes run in the host process, `.gd_cube_fn()` and the upper kernel of `.gd_host_kernel()`, stay closures and cross nothing. Ending the two paths is what would retire the machinery listed at the end of section 2.
- **One kernel cache.** Every kernel goes through `.daemon_kernel()` at one cap, `.kernel_cache_max`, on the daemons and on the host. The per-route caches are gone, so the cap in section 6 holds on every route, and closure kernels share it.
- **A figure nobody tunes is a constant beside its use.** The option table keeps the `user` and `tuning` tiers, and any other `garry.*` name aborts at run start and at `garry_daemons()`. `ram_budget_mb` bounds one kernel call, for chunks and for fused tiles. `exec_ram_fraction` bounds committed memory in the scheduler and in the fetch-ordered pipeline.
- **A value nothing produced is an error.** A failed read aborts on every route, and NaN reaching an integer upload raises `garry_nodata_error`. There is no hole option and no substituted 0. This is the same rule as section 6's kernel failures: nothing is retried down another path.
