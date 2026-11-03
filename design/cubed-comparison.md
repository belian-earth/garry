# garry and Cubed: what the engine structures teach

Status: design note, 2026-10-30. A learning exercise, not a proposal to adopt or replace anything. garry keeps its closed primitive set, GDAL as the sole I/O boundary, and no arbitrary R.

Sources: garry at `6da327d`; Cubed at `ba4c7f7` (2026-10-23), read through the GitHub API. Nothing was run on either side, so every performance statement about an untested idea is inference and is labelled. Earlier conclusions in `design/deep-review-2026-07-31/` are not repeated; section 6 records where this note touches them.

Citations are `file::function`, relative to each repository. Where a function is named alone, it lives here:

- `R/passes.R`: `.plan_chunk_dim`, `.plan_read_px`, `.chunk_for`, `.stage_bytes_per_px`, `.stage_fuse_act_bytes_px`, `.merge_stages`, `.stage_strip_rows`, `.stage_export_pads`, `.plan_lazy_impl` and its locals `read_px_of`, `fuse_px_cap`, `stage_objs`, plus `.collapse_band_stacks`, `.dedup_warps`, `.reduce_partial_fn`, `.reduce_combine_fn`.
- `R/scheduler.R`: `execute_plan_mirai` and its locals `add_task`, `read_ok`, `comp_ok`, `store_ok_comp`, `refresh_mem_budgets`, `task_order`, `dep_of`, `max_set_mb`, plus `.store_gate_comp`, `.store_region_mb`, `.stage_kernel_sig`, `.task_mirai`, `.task_log_memory`.
- `R/executor.R`: `.exec_split_cg`, `.exec_read_padded`. `R/ops.R`: `.g_map_row_strips`. `R/placement.R`: `.plan_placement`, `.fuse_tiles`, `garry_explain_placement`. `R/lazy_raster.R`: `.lazy_binop`, `lazy_map`. `R/grid.R`: `grid_diff`. `R/chunk_grid.R`: `chunk_window_with_halo`, `snap_to_blocks`.
- `cubed/core/ops.py`: `blockwise`, `rechunk`, `_rechunk`, `_rechunk_plan`, `split_chunks`, `merge_chunks`, `map_selection`, `_assemble_index_chunk`, `map_blocks`, `reduction`, `partial_reduce`, `_partial_reduce`, `tree_reduce`, `_normalize_split_every`, `scan`, `unify_chunks`, `smallest_blockdim`.
- `cubed/primitive/blockwise.py`: `can_fuse_multiple_primitive_ops`, `peak_projected_mem`, `fuse_blockwise_specs`, `make_fused_function`. `cubed/core/optimization.py`: `multiple_inputs_optimize_dag`, `fuse_predecessors`, `can_fuse_predecessors`, `fuse_only_optimize_dag`.
- `cubed/primitive/memory.py`: `MemoryModeller`, `BufferCopies`. `cubed/core/array.py`: `measure_reserved_mem`. `local.py` means `cubed/runtime/executors/local.py`.
- `reports/` means `~/belian/bench-run/large-units-2026-10-30/reports/`.

Terms used throughout. A **chunk** is the unit a compute task works on. A **read window** is garry's coarser unit for reads. **Fusion** folds several operations into one task. **Admission** is the runtime decision to launch a task. The **store** is garry's shared-memory region pool (`mori`), which holds values between tasks. Cubed's **projected memory** is its plan-time estimate of one task's peak.

## 1. Key findings

1. **The engines bound memory in different places because they keep intermediates in different places.** Cubed writes every intermediate to Zarr, so tasks share no memory and a task's footprint depends only on chunk size. garry keeps intermediates in RAM, so its footprint depends on scheduling and must be admitted at runtime. Cubed's bound is structural for data sizes. It is declared, not derived, for operation working memory (section 3.3).

2. **Cubed's chunk size is an input; garry's is an output.** Cubed takes chunks from the user or the source and then checks them. garry derives them from the merged stages. So in Cubed fusion yields to chunk size: a fusion that breaks the budget is refused. In garry fusion moves chunk size, which is how one map inflated a predict plan's tasks 18x (`R/passes.R::.merge_stages`, comment).

3. **garry needs no rechunk, and that follows from two design choices.** `ChunkGrid` tiles only x and y, so a chunk always holds every t and band; and GDAL reads any window. garry's read-window split is a one-stage in-memory rechunk, with the store as its intermediate and `read_budget_mb` as its memory limit. At this commit Cubed's rechunk is no longer a primitive: it is a chunk-planning algorithm over `map_selection`, which is itself blockwise.

4. **The most useful lesson for the 87-stage tail is how Cubed fuses, not how much.** Cubed composes per-operation functions inside one task, with no compile step. The `stablehlo-kernels` spike merges stages into one program, which gives up kernel sharing. A third option follows: run several already-compiled kernels in one task. That keeps the 9 kernels and removes the per-stage host and store traffic (inference, idea 2).

5. **The most useful memory lesson is `MemoryModeller`.** Cubed replays allocate and free over a sequence of operations to get a peak. Applied to one chunk's stage chain, this gives a static per-chunk live set, and reserving that set at admission bounds the store independently of scheduler speed. That is the property `reports/garry-audit.md` section 7a finds missing (idea 3).

6. **Cubed tests its model against measurement; garry does not.** `cubed/tests/test_mem_utilization.py::run_operation` asserts measured peak against projection for each operation. No garry test compares a measured peak with a modelled one: `tests/testthat/test-mem-admission.R` checks correct completion under squeezed budgets, and `test-task-report.R` checks log parsing.

7. **garry is ahead on most of the engine.** Compiled fusion with content-addressed kernel sharing, byte admission against live cgroup-aware RAM, a zero-copy store, warp-on-read, and a t axis that makes median and Kalman chunk-local (section 3.7).

## 2. Chunking side by side

| Aspect | garry | Cubed |
|---|---|---|
| Who decides | The planner: `R/passes.R::.plan_chunk_dim` | The user or the source: `chunks=` at creation, Zarr chunks in `cubed/core/ops.py::from_zarr`. `"auto"` targets 128 MiB (`cubed/vendor/dask/array/core.py::auto_chunks`) |
| When | Once per plan, in `.plan_lazy_impl` phase B, after stage merge | At array creation; each op derives its output chunks in `cubed/core/ops.py::blockwise` |
| Inputs | `chunk_target_px` (1e6), `ram_budget_mb` (512), the worst stage's `.stage_bytes_per_px`, native blocks | Shape, dtype, input chunks. `allowed_mem` never sets a chunk size; it feeds rechunk planning, the projection check and the fusion gate |
| Axes split | x and y only (`R/chunk_grid.R::ChunkGrid`) | Every axis |
| Variation | One tiling per plan, with named exceptions (section 3.1) | Every array has its own chunks |
| Levels | Read window contains chunk contains row tile or strip | Chunk, plus `copy_chunks` in rechunk and `merge_chunks` for coarser reads |
| Against storage | Snap to the LCM of native blocks unless above 2x the side; GDAL hides the rest | Chunks are the unit of both storage and computation (`docs/design.md`) |
| Input mismatch | Cannot occur: grids must match (`.lazy_binop`, `lazy_map`) and the tiling is shared | `cubed/core/ops.py::unify_chunks` rechunks to the smallest |
| Role of memory | Caps chunk size | Checks chunk size |
| Over budget | Warns and serialises (`execute_plan_mirai`) | Raises before any task (`cubed/core/plan.py::FinalizedPlan.validate`) |
| Edge chunks | Grown to the modal shape so one kernel serves all (`R/executor.R::.chunk_grow`, `.sv_grow`) | Smaller last chunk; projection uses `largest_chunk` |
| Task table | Materialised per stage and chunk (`execute_plan_mirai`, `add_task`) | Enumerated lazily per op (`cubed/primitive/blockwise.py::ChunkKeys`) |

## 3. The seven questions

### 3.1 How is chunk size decided?

**garry.** `.plan_chunk_dim` takes `min(chunk_target_px, ram_budget_mb / max(bytes_per_px))` over all stages, floors its square root, and snaps with `snap_to_blocks`. A patch stage replaces the target with the RAM cap. The inputs are static options, so chunking does not depend on the machine. The worst stage sets the tiling for all: a bidirectional scan at T = 19 charges 8 x 20 x 19 = 3,040 B/px from `scan_px` alone (`.stage_bytes_per_px`), which caps a chunk near 176,000 px, side 420. The 512 cell chunk in `reports/garry-audit.md` fits that figure snapped up to a block (inference).

The tiling is plan-wide because executors align input chunks by index (`.plan_chunk_dim`, comment). The exceptions are:

- `source_read` and `warp` stages read at an integer multiple of the chunk (`.chunk_for`), sized per source by its consumers (`read_px_of`, `.plan_read_px`) and capped for fusable chains (`fuse_px_cap`).
- `reduce_combine` takes the whole grid (`.chunk_for`).
- A coarsened warp sink has its own square chunk (`stage_objs` in `.plan_lazy_impl`).
- Below the chunk, kernels subdivide: pointwise fused kernels by row tiles (`R/placement.R::.fuse_tiles`), scans by row strips (`.stage_strip_rows`).

**Cubed.** No code derives chunk size from memory. `allowed_mem` appears in `cubed/core/ops.py` only to pass into primitives and in `_rechunk_plan`. `blockwise` takes output chunks from its inputs, `reduction` shrinks reduced axes through `combine_sizes`, and any array may differ from its neighbours. The guidance is manual: about 100 MB chunks, and `allowed_mem` at least ten times the chunk (`docs/user-guide/memory.md`, `docs/user-guide/scaling.md`).

The bytes are comparable. A 1e6 px chunk over 19 f32 slices is 76 MB. The difference is shape: garry's chunk is a column through t and band, while the thin per-stage outputs inherit the same x and y tiling.

### 3.2 Chunk mismatches and rechunk

**Between inputs.** Cubed's `blockwise` calls `unify_chunks`, which picks `smallest_blockdim` and inserts `rechunk` on the others. Those rechunks cannot fuse, so a mismatch costs a stage. garry refuses the mismatch at the API (`.lazy_binop`, `lazy_map`, with `grid_diff` in the message) and then needs no alignment step, because every compute stage shares one tiling.

**Between storage and compute.** Cubed's chunks are its storage blocks, so mismatch arises only on selection. `map_selection` turns a selection into block keys and reads them one at a time through an iterator (`_assemble_index_chunk`). `from_zarr(chunks=)` uses `merge_chunks`, which demands exact multiples. garry leaves blocks to GDAL. A read window may cut blocks, and only the LCM snap and the full-width row bands for strip sources (`.chunk_for`) reduce the overlap.

**What rechunk does.** `rechunk` calls `_rechunk_plan`, which derives `max_mem = (allowed_mem - reserved_mem) / total_copies` and `min_mem = max_mem / 20`, then runs a multi-stage plan (`cubed/vendor/rechunker/algorithm.py::multistage_rechunking_plan`, or `cubed/core/rechunk.py::multistage_regular_rechunking_plan`). `consolidate_chunks` grows reads up to the memory limit. Each stage is a `_rechunk` op: a `map_selection` that reads one `copy_chunks` region and writes several `target_chunks` blocks, marked non-fusable, with intermediates in Zarr. `cubed/primitive/rechunk.py` no longer exists; `docs/design.md` still names it.

**Why garry does not need it.** Rechunk exists mainly to swap which axis is contiguous, and to do so across arrays too large to hold. garry's chunks always contain all of t, and a GDAL window can be taken from any source at any position, so no data is reorganised.

**What garry does instead.** A read task reads one coarse window, slices it producer-side into per-compute-chunk parts, and shares them as one list (`R/daemon.R::.daemon_run_source_shm`). `.exec_split_cg` builds the fine table and asserts integer multiples. `dep_of` maps each compute chunk to its read task. Halo rides on both the window and the parts. Structurally this is one rechunk stage, with three differences: the intermediate is RAM and refcounted, it runs once, and windows must be unions of chunks where rechunk may use irregular intermediates (`cubed/core/ops.py::split_chunks`).

**What garry lacks.** A cost estimate. Rechunker scores a plan with `calculate_single_stage_io_ops`; `.plan_read_px` takes the largest window the budget allows and does not count block reads. The one-stage form degrades when windows shrink toward block size as bands grow, and a fixed `read_budget_mb` brings that point closer than the machine requires (idea 7).

### 3.3 How memory is bounded and verified

| | garry | Cubed |
|---|---|---|
| What is bounded | Task working sets, the shared store, and the fleet in flight | One task; the fleet is `allowed_mem x max_workers` |
| Model | `.stage_bytes_per_px` plus a /2 discount in `execute_plan_mirai`; `.fuse_tiles`; `.stage_fuse_act_bytes_px`; `.store_region_mb` | `cubed/primitive/memory.py::calculate_projected_mem`: reserved, inputs x (1 + read copies), extra, output x (1 + write copies) |
| Budget | 0.6 of live available RAM (`exec_ram_fraction`), reads at most a third (`refresh_mem_budgets`) | Static `allowed_mem` (2 GB) including `reserved_mem` (100 MB), from `cubed/__init__.py` |
| When checked | At each launch; budgets re-read every 5 s | Once before running (`FinalizedPlan.execute`), and once against machine total (`local.py::check_runtime_memory`) |
| Machine view | Least of host free and cgroup headroom (`R/pools.R::.garry_ram_avail_mb`) | `psutil.virtual_memory().total`: not available RAM, no cgroup |
| Runtime reaction | RSS correction and `/dev/shm` clamp (`refresh_mem_budgets`) | None |
| Measurement | Per-daemon `RssAnon`, cgroup and shm sampled at 5 s (`.task_log_memory`) | Per-task `ru_maxrss` (`cubed/runtime/utils.py::execute_with_stats`), Memray for one task per op |

**Is Cubed's bound by construction?** Partly. Three structural facts carry it. Tasks share nothing, so memory does not accumulate across tasks or depend on order. Each input array contributes one chunk to the projection. Multi-block reads use iterators, so `_partial_reduce` and `_assemble_index_chunk` hold one block at a time (`cubed/primitive/DESIGN.md` makes the list and iterator distinction explicit). What is not by construction is `extra_projected_mem`, which each operation declares by hand: `scan` passes `scanned.chunkmem * 2` with the comment `# arbitrary`, and the comment in `partial_reduce` reasons from observed behaviour ("maybe because the iterator doesn't free the previous object"). User function memory in `map_blocks` is unmodelled, and `docs/user-guide/memory.md` calls the result a conservative upper bound, not a proof.

**When a projection is wrong.** If it exceeds `allowed_mem`, `validate()` raises before any task runs. If it is too low, nothing reacts. A task that exceeds its limit fails like any other and is retried where the executor retries. `cubed/diagnostics/mem_warn.py::MemoryWarningCallback` warns after the run, if attached.

**Peak measurement has gaps.** `ru_maxrss` is a process high-water mark, so a reused process hides any task below its previous peak; the test suite adds `max_tasks_per_child=1` for "a stronger check on peak memory". The default threads executor measures nothing: `local.py::run_func_threads` uses `execution_timing` only.

**garry's bound is soft by design.** `.stage_bytes_per_px` says of itself "An estimate, not a bound". The store has no Cubed analogue, and it needs escape hatches to avoid deadlock: `read_ok`, `.store_gate_comp`, `comp_ok`, and budgets floored at `store_mb_max` and `task_mb_max`. The comment on `store_ok_comp` states that the store can run past the budget and relies on the shm backstop. garry's model is live and covers heterogeneous tasks; Cubed's is static and holds by structure. Each has what the other lacks, and ideas 1 and 3 take Cubed's half.

### 3.4 Plan representation and fusion

**Cubed** has one level: a NetworkX `MultiDiGraph` of op and array nodes (`cubed/core/plan.py::Plan`). An op holds a `CubedPipeline` whose `mappable` yields output-chunk coordinates, and a `back_key_function` runs on the worker to find its inputs. No chunk-level graph exists anywhere, on client or worker.

**garry** has three levels: an IR node graph, a `Plan` of stages (`R/plan.R::Stage`), and a task table built at execution (`add_task`), with dependencies, refcounts and per-task bytes. Chunk-level state is what refcounted store drops require.

**How Cubed fuses.** `multiple_inputs_optimize_dag` makes one topological pass of `fuse_predecessors`. `can_fuse_predecessors` and `can_fuse_multiple_primitive_ops` refuse when:

- the op or every predecessor is flagged non-fusable, as rechunk is both ways;
- the array has more than one dependent, or is a requested output;
- a predecessor has multiple outputs;
- total source arrays exceed 4 with more than one predecessor (`DEFAULT_MAX_TOTAL_SOURCE_ARRAYS`);
- `peak_projected_mem` of the predecessors exceeds `allowed_mem`;
- total input blocks exceed 10 (`DEFAULT_MAX_TOTAL_NUM_INPUT_BLOCKS`).

The docs give the reason for the counts: reads per task, not memory (`docs/user-guide/optimization.md`). `fuse_blockwise_specs` then composes back key functions and functions separately. The fused function is a Python closure over the originals (`make_fused_function`).

**How garry compares.** The single-consumer rule is shared. `.merge_stages` adds equal spatial grids, no halo, the seal, and no reduction or scan into a join; those guards protect correctness and the dependency frontier, and none prices memory. Read fusion is separate and better: `.plan_placement` prices FLOPs, movement, widths and working sets at execute time.

**The difference that matters.** Cubed's fusion costs nothing to compile and loses nothing to share, so its limits are only memory and reads. garry's fusion produces a new program, with a compile, a lost kernel share, and a wider frontier (`design/stablehlo-kernels.md` section 3). The 87 stages already share 9 compiled programs through `.stage_kernel_sig`, and folding them into one program trades that sharing away. That is consistent with the spike not being a clear win; the spike's results table is still a placeholder, so this rests on the brief.

### 3.5 Overlap, halos and multi-chunk reductions

**Halos.** `cubed/array/overlap.py::map_overlap` is `map_selection` with a depth: each output block reads up to 3 input blocks per overlapped axis (`_overlap_num_input_blocks`), then `_pad_boundaries` fills constants at the array edge. It takes one input array, constant boundaries, and no trim. Neighbours are read from the materialised input, so nothing is recomputed, but whole blocks are decoded for a thin ring.

garry satisfies a halo at the leaves by enlarging the read window (`chunk_window_with_halo`, `.exec_read_padded`), and across compute stages by recomputing a ring (D22, `design/halo-propagation.md`). `out_pad` propagates backwards in `.plan_lazy_impl`, and `.stage_export_pads` mirrors the runtime pad walk. Ring recompute keeps chunks independent, and it costs 0.4 % of cells at radius 1 on 1024 square chunks. Its known weak case is a wide patch kernel: 2.1x recompute at 128 px on 580 px chunks (`.plan_chunk_dim`, comment), answered by choosing the largest chunk.

**Reductions over chunks.** Cubed's `reduction` runs `partial_reduce` and then `tree_reduce`: rounds of `split_every` blocks (default 4), depth logarithmic in block count. `_partial_reduce` folds one block at a time with bounded memory. Median is not in the tree: `cubed/array/nan_functions.py::nanmedian` rechunks the axis into one chunk first, then maps.

garry never faces this for t or band, since those reductions are chunk-local in one program. For x and y it has one level: `reduce_partial` per chunk, then `reduce_combine` on the host (`.reduce_partial_fn`, `.reduce_combine_fn`), with algebraic ops only (D12). Partials are small, so a tree would gain nothing.

**Scans.** Cubed's `scan` is a Blelloch-style recursion for associative operators such as `cumsum`. garry's `ScanNode` carries arbitrary state over an unchunked axis, which is what makes a Kalman smoother a single kernel.

### 3.6 Runtime

| | garry | Cubed |
|---|---|---|
| Task | One read window, one stage and chunk, or one fused window | One output chunk, or one rechunk copy region |
| Executor | Central R loop over mirai pools; read, compute and writer roles (`execute_plan_mirai`) | Pluggable `DagExecutor`; default threads, also processes, Lithops, Modal, Dask and others; workers stateless |
| Order | Priority, then window-major (`task_order`); chunk-level readiness | One op at a time in topological order (`visit_nodes`), or by generation if `compute_arrays_in_parallel` |
| Overlap of stages | Yes, the launch order relies on it | No, an op completes before the next starts |
| Intermediates | RAM store, refcounted, dropped on last consumer | Zarr, compressed, kept to end of run |
| Retries | `read_retry` for reads and fetches, `garry_jit_miss` resend, otherwise fail | 2 retries (tenacity, Lithops); none on processes (`docs/configuration.md`); timeouts per executor |
| Stragglers | None | `cubed/runtime/backup.py::should_launch_backup`: 3x the median once half done; cloud stores only by default |
| Backpressure | Slot caps, byte budgets, store gate | `max_workers`, optional `batch_size` |
| Client loop | 2 ms poll, sweep over pending tasks | `asyncio.wait` with 2 s timeout, no per-task dependencies |
| Cost per task | About 410 us dispatch (`options.R`), 17 us per pending task on each sweep, about 60 ms a task in large tails (`reports/index-forensics.md` section 9) | At least one Zarr read and write. Not measured here |

Cubed's client is cheap because order is implicit in the op sequence. garry's host cost comes from overlap and refcounts, which is the price of keeping intermediates in RAM. `docs/user-guide/scaling.md` names Cubed's price: the number of steps sets the minimum total time, and every intermediate is written to storage (`docs/computation.md`).

### 3.7 What would not suit GDAL raster work, and where garry leads

**Would not suit:**

- **Zarr chunks as the unit of compute.** A warp has no fixed block mapping; the warper decides what it reads. A window is the natural unit.
- **Writing every intermediate to storage.** The tail's small regions would each cost a storage round trip. Cubed's docs name this as the model's main disadvantage (`docs/computation.md`), and its answer is more fusion.
- **Uniform per-worker reservation.** `allowed_mem x max_workers` treats a 10 MB mask task and a 2.4 GB fused window alike (figures from `design/deep-review-2026-07-31/execution-vs-dask.md`), so the widest op sets concurrency for all.
- **A source-array fan-in of 4.** A median over 145 inputs is routine in garry and could not fuse in one step under that default.
- **Stateless workers.** They would discard the GDAL block cache, open handles and compiled kernels, which garry's scheduling is built to reuse.

**Where garry is ahead:**

- Kernels compile below the task boundary, and `.stage_kernel_sig` shares them across stages. Cubed fuses Python closures. It has a `compile_function` hook (`cubed/core/plan.py::_compile_blockwise`) that wraps each op's function, with no sharing between ops.
- Admission uses bytes against live RAM and cgroup headroom, where Cubed compares a static figure with machine total once.
- `.plan_placement` has no Cubed counterpart. `cubed/core/optimization.py` holds fusion passes only, with no cost model.
- Plan-time rewrites `.collapse_band_stacks` and `.dedup_warps` shape reads to the file's storage.
- Edge chunks reuse one kernel, and t-local median and scan avoid rechunk altogether.

## 4. Ideas worth learning from, ranked

Every code change below must pass the general-improvement rule: A/B wall and physical memory across workload shapes, not correctness alone (`reports/garry-audit.md` section 7a, `design/stablehlo-kernels.md` section 5). All nine fit the ethos unless noted; none needs a storage change. Fixtures are in `reports/garry-audit-scripts/`.

**1. A model honesty test and per-task peak memory.**
- *Problem:* the memory model is unverified except by incident. It was 70x low in the tail and high in prediction (`reports/index-forensics.md` section 6), and the same quantity is expressed in several formulas (section 3.3).
- *From Cubed:* `run_operation` asserts measured against projected per op; `measure_reserved_mem` replaces a guessed baseline with a measured one; `calculate_projected_mem` is one formula with separable terms.
- *For garry:* return a per-task peak through the `.task_mirai` timed envelope and log it beside `mb`. On Linux, `VmHWM` can be reset between tasks through `/proc/self/clear_refs` (proc(5)), which beats Cubed's delta on reused daemons. `VmHWM` counts mapped store pages, so report `RssAnon` too. Add a slow test per stage class at two chunk sizes that asserts peak against modelled `mb` and prints the ratio. Measure `cost_xla_client_mb` at `garry_daemons()` start instead of calibrating it.
- *Ethos:* fits; logging and tests only.
- *Test:* the ratio table is the result. Check the cost of one `/proc` read per task on a tiny plan, as `overhead.R` does for a collect. The closure defect should appear as a per-task outlier. Ideas 2 to 4 depend on this.

**2. Task-level composition: several compiled kernels in one task.**
- *Problem:* about 70 compute stages per chunk in the tail, tasks of 5 to 11 ms running at the host's pace, and every stage output passing through the store. One merged program loses kernel sharing and widens the frontier.
- *From Cubed:* `make_fused_function` composes unchanged per-op functions inside one task, and intermediates stay in process.
- *For garry:* a chain task that fetches k kernels by cache key, runs them in order for one chunk, passes device buffers between them, and writes only values leaving the chain. `.daemon_run_compute_shm` already holds the pieces: cache lookup, upload, call, download. Tasks fall from stages x chunks to chains x chunks (inference). The cost is no cross-stage XLA optimisation. Chains should stop where a late input would hold the chain back, and scan stages keep their confinement.
- *Ethos:* fits; it changes scheduling granularity only.
- *Test:* `tail-fixture.R` in three arms: split, `stage_merge = "auto"` where it folds the group, chain. Compare tasks, wall, drain, compute busy, shm peak and compile count.

**3. A static per-chunk live set and chunk-level reservation.**
- *Problem:* the ready-set sweep removed an accidental throttle and failed 2 of 2 at 6 daemons and 7 GB, because the store escape let outputs outrun consumers (`reports/garry-audit.md` section 7a). Escape hatches make the store's overshoot unknowable in advance.
- *From Cubed:* `MemoryModeller` and `peak_projected_mem` replay allocate and free; Cubed's bound does not depend on scheduler speed.
- *For garry:* at plan time, walk one chunk's stage order, allocate each export, free it after its last consumer, and take the peak as `chunk_live_mb`. At launch, admit a new chunk only if resident bytes plus K x `chunk_live_mb` fit, with K at least `n_comp`. Tasks of an admitted chunk need no store gate because their peak is already reserved, so they cannot deadlock. Overshoot is then at most `n_comp x chunk_live_mb`, known before the run (inference). Read windows keep their own gate.
- *Ethos:* fits; the store is untouched.
- *Test:* the audit's failing arm, 6 daemons at 7 GB with the ready set: pass is 2 of 2 complete, wall no worse than the old sweep, and physical shm peak within the computed bound. Then the 8 GB arm, where shm rose from 1,438 to 2,369 MB.

**4. A strip-aware chunk cap.**
- *Problem:* the worst stage caps the whole tiling. `scan_px` charges 20 cubes over the full chunk, and `.plan_chunk_dim` runs before `.stage_strip_rows`. A stripped scan runs strips in sequence inside one program (`.g_map_row_strips`), so body state should be live for one strip at a time, plus the exports (inference). Strips were added for cache bandwidth, and no memory effect has been measured (`.scan_strip_px`, `passes.R`).
- *From Cubed:* an op's cost is its own and does not change other arrays' chunks. `ram_budget_mb` already separates kernel working set from window size for fused reads; this applies the same principle to scans.
- *For garry:* if measured peak tracks strips, charge body state per strip. A 512 chunk moving to the 1e6 px ceiling gives 3.8x fewer chunks, and the tail fit's T squared term (`reports/garry-audit.md` section 4) falls about 14x (inference, and other stages may still bind).
- *Ethos:* fits.
- *Test:* with idea 1, measure a bidirectional scan at 512 and 1024, strips on and off. Only then A/B `tail-fixture.R`, raising `garry.ram_budget_mb` so the cap moves. Note `strip_rows` is part of the kernel key.

**5. Size first, then fuse within the budget.**
- *Problem:* `.merge_stages` has no memory guard, and sizing follows merging, so one merge can reshape the whole plan. The spike already sizes on unmerged stages (`.merge_chunk_pipelines`) and needs a per-plan rule.
- *From Cubed:* chunks are fixed before fusion, and `can_fuse_multiple_primitive_ops` refuses on `peak_projected_mem`. Debug logging states each refusal. `fuse_only_optimize_dag` pins fusion to named ops for experiments.
- *For garry:* after tiling, allow a merge only if the merged footprint fits `ram_budget_mb` and its input set does not shrink read windows. Record the reason as `garry_explain_placement` does. Add a fuse-only list so the spike can test groups, not only all or nothing. Cubed's counts of 4 and 10 do not transfer, since garry's reads run in separate tasks.
- *Ethos:* fits.
- *Test:* stage and task counts on `test-planner-golden.R` plans; the 18x predict case must not inflate; then A/B with `predict-fixture.R` and `tail-fixture.R`.

**6. Plan statistics before running.**
- *Problem:* task blow-ups show only after a run. `R/plan_view.R` has no chunk, task or memory field, and `garry_explain_placement` covers placement only.
- *From Cubed:* `FinalizedPlan` exposes `num_tasks`, `max_projected_mem`, `total_nbytes_written` and `exceeds_memory`, and `visualize` marks over-budget ops.
- *For garry:* per-stage chunks, tasks, modelled `mb`, store bytes and distinct kernels, computed without daemons. Today these live inside the task build in `execute_plan_mirai` and need factoring out.
- *Ethos:* fits.
- *Test:* snapshot on golden plans; the 18x case and the 87-stage tail are visible without executing.

**7. Keep planning sizes apart from admission budgets.**
- *Problem:* `read_budget_mb` sizes windows in `.plan_read_px` and gates launches in `read_ok`, at a fixed 4,096 MB on a 491 GB worker (`reports/garry-audit.md` section 1).
- *From Cubed:* the plan depends on `allowed_mem`, concurrency on `max_workers`, and the two meet only in `check_runtime_memory`. This confirms the audit's item 4 and adds one reason: machine-independent chunk tables keep plans comparable between laptop and worker.
- *Ethos:* fits.
- *Test:* OE predict with a raised admission budget: identical chunk tables, less reader time gated.

**8. Integer-multiple tilings for compute stages (speculative).**
- *Problem:* cheap pointwise stages inherit the tiling of the worst stage.
- *From Cubed:* arrays carry their own chunks, and `merge_chunks` demands exact multiples. `.exec_split_cg` already handles coarse to fine under the same rule.
- *For garry:* fine to coarse needs a gather, which costs a copy, and it reaches store keys, edge growth and kernel shapes.
- *Ethos:* fits, at high cost. Worth it only if ideas 2 and 4 leave tiny tasks dominant.
- *Test:* first count tail tasks at k = 2 and 4 from the plan alone, extending `chunk-spike.R`.

**9. Streaming algebraic reductions over t (speculative).**
- *Problem:* a stage's co-resident inputs set its read window and floor the store (`.plan_read_px`, `max_set_mb`).
- *From Cubed:* `partial_reduce` declares an iterator of inputs, and memory stays at one block plus two reduced values.
- *For garry:* batch a long `sum`, `mean`, `min`, `max` or `count` over t into partials. It does not apply to median, the main composite.
- *Ethos:* fits.
- *Test:* first count production plans with algebraic t reductions over many inputs. If few, drop it.

## 5. Checked and not worth taking

- **Multi-stage rechunk.** Random-access windows and an unchunked t remove its purpose (section 3.2). Only its cost estimate survives, and only as a diagnostic.
- **Automatic `unify_chunks`.** Explicit `align_to()` is a recorded decision, and an inserted rechunk hides the cost.
- **Op-at-a-time execution.** It removes Cubed's scheduling cost, but in RAM it would hold a whole stage's outputs at once, and it would end per-band tail overlap. It works for Cubed only because intermediates are on disk.
- **Speculative backup tasks.** They need idempotent outputs and atomic writes. garry's slow OE windows took the same time on first and second pass, p50 9.5 and 9.7 s (`reports/index-forensics.md` section 5), so a duplicate would be no faster.
- **Resume from intermediates.** `cubed/core/plan.py::already_computed` needs persisted arrays. hutan's per-box execution is the natural restart unit (inference).
- **Raising when over budget.** garry's model is not yet a bound, so a hard error could reject runnable plans. Serialise and warn stays right until idea 1 shows otherwise.
- **Tree reduction over space.** Partials are small, and the host combine is one step.
- **Neighbour-block overlap.** It needs materialised inputs and decodes whole blocks. Ring recompute holds at the radii in use.
- **`BufferCopies` constants.** They describe Zarr and cloud paths. Only the formula's shape survives, in idea 1.
- **Blelloch `scan`.** It solves a chunked axis that garry does not have, and only for associative operators.
- **`max_tasks_per_child` in production.** Recycling would discard compiled kernels. It is useful in the test harness only.
- **Virtual arrays.** XLA constants already cover small fixed values, and `stablehlo-kernels.md` section 4 tracks constants as inputs.

## 6. Notes and limits

- **Earlier reviews.** The HLG rejection in `design/deep-review-2026-07-31/SYNTHESIS.md` stands. Cubed's lazy `mappable` is attractive, but refcounted drops need chunk-level state, and the audit's cost is the pending walk, which a ready set addresses. Dask's "estimates drift" conclusion is reinforced: Cubed reaches the same concern by testing, not by runtime reaction.
- **Stale Cubed docs.** `docs/design.md` names `cubed.primitive.rechunk`, which is absent. `docs/user-guide/scaling.md` says larger `allowed_mem` means fewer reduction steps, but `_normalize_split_every` defaults to 4 and does not read `allowed_mem`. `docs/user-guide/optimization.md` shows an older debug message than `can_fuse_predecessors` prints.
- **A garry doc mismatch.** `chunk_target_px` is described as a minimum (`R/options.R`), but `.plan_chunk_dim` uses it as a ceiling except for patch stages. Chunks therefore do not grow on large machines.
- **Unverified.** All arithmetic on task counts is from the formulas and the audit's fits. `.stage_bytes_per_px` figures assume the audit's T = 19. The memory effect of strips is unmeasured. Cubed's cost per task was not measured.
