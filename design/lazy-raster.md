# Lazy raster: design notes

Status: brainstorming / pre-implementation. Captures the architecture worked
out in discussion; not yet validated in code.

## Motivation

`vrtility` gets excellent performance on heavy remote-sensing workloads by
combining GDAL (via `gdalraster`) with async, block-wise execution (via
`mirai`). Its limitation is the VRT model itself: XML-based, awkward to
compose, hard to extend beyond what GDAL pixel functions express.

The proposal is a package that keeps vrtility's strengths — GDAL-owned IO,
distributed block processing via mirai — but replaces VRT as the central IR
with an R-native lazy array abstraction, and makes `anvil` (XLA-backed JIT)
the **primary compute backend** rather than an optimisation.

That second choice is what separates this from a reskin of vrtility. With
anvil as the compute layer, the package is not just a remote-sensing IO
tool: it is a CRS/transform-aware **numerical computing platform for
rasters**. Fused kernel graphs, GPU dispatch, and reverse-mode
autodifferentiation over pipelines are all in scope. Modelling workflows —
hydrology, ecology, energy balance, inversion, calibration — become
expressible natively in R without exporting to Python.

This maps to xarray + dask + rioxarray for structure, and to JAX for the
compute semantics.

## Architectural layers

Four layers, each with one job:

1. **User API (`LazyRaster`)** — array-like, CRS/transform-aware, composes
   lazily. Users never see nodes or graphs.
2. **IR (`Graph` + `Node`)** — a logical DAG of operations. Built by the
   user API; consumed by the planner.
3. **Planner** — passes that validate, propagate halos, compose fusable
   ops into one R function, pick chunk grids, emit a physical task graph.
4. **Executor** — a ready-queue scheduler that dispatches chunk tasks via
   `mirai`, calling anvil-compiled kernels on `AnvilArray` chunks.

## Foundations

| Package      | Role                                                              |
|--------------|-------------------------------------------------------------------|
| `vaster`     | Pure grid math: pixel↔world, extent/dim snapping, cell index.     |
| `gdalraster` | GDAL bindings: windowed reads, VRT construction, writing.         |
| `anvil`      | **Compute backend.** `jit()` wraps standard R functions into XLA  |
|              | kernels over `AnvilArray` (dtype + device). `gradient()` for AD.  |
| `mirai`      | Daemons and dispatch for distributed chunk-task execution.        |
| `S7`         | Object system for IR nodes and user types.                        |

Convention boundary: vaster coords are the internal language; gdalraster
adapters translate at IO. GDAL's 0-based conventions do not leak into the
middle of the graph.

## Role of anvil

anvil accepts standard R functions: `f_jit <- jit(f)`, then
`f_jit(a, b, x)` executes a compiled XLA kernel. Arrays are
`AnvilArray` values carrying dtype (e.g. `f32`) and device
(`CPU`, `CUDA`, `Metal`). `gradient(f, wrt = c(...))` returns a
reverse-mode-differentiated function.

Implications for this package:

- **`AnvilArray` is the native chunk type.** Our internal chunk data is
  `AnvilArray`, not base R arrays. `GridSpec$dtype` aligns with anvil dtype
  strings. Base R arrays convert at IO boundaries only.
- **Fusion is handled by XLA.** Our "fusion pass" is just a composition
  pass: adjacent fusable nodes are assembled into one R function, which is
  then `jit()`-wrapped. XLA does the actual fusion inside.
- **No interpreted fallback.** If a node can't be expressed as a
  jit-compilable R function, the planner rejects it. Two compute paths
  create two bugs; one path forces the expression surface to stay
  well-defined.
- **Devices are first-class.** mirai daemon pools can be tagged by device;
  the scheduler dispatches GPU-eligible kernels to GPU daemons.
- **Autodiff is a feature, not a side-effect.** `gradient(pipeline)`
  returns a differentiable function over the lazy graph — usable for
  inversion, assimilation, model calibration, and NN-style training over
  raster stacks. This only works because anvil is the single compute
  backend.

## Grid and alignment model

A `GridSpec` is a typed, validated object:

```r
GridSpec <- new_class("GridSpec", properties = list(
  crs       = class_character,
  transform = class_numeric,   # length 6
  extent    = class_numeric,   # xmin, ymin, xmax, ymax
  dim       = class_integer,   # nx, ny, (nt, nb optional)
  dtype     = class_character  # aligns with anvil dtype
))
```

Every `LazyRaster` carries a `GridSpec`. Binary ops require grid equality.
Mismatches do not silently auto-resample: the user calls `align(a, b,
to = ...)` which injects a `WarpNode` (backed by a lazy VRT at execution).

VRT is a compiler pass, not the IR.

## IR: Node hierarchy

Node types (S7 classes inheriting from an abstract `Node`):

- `SourceNode` — wraps a gdalraster handle + read window.
- `MapNode` — elementwise function.
- `FocalNode` — kernel + halo radius + boundary policy.
- `ReduceNode` — reduction over named dims; barrier.
- `WarpNode` — lazy VRT warp (output of `align()`); barrier.
- `StackNode` — combine along a dim (e.g. time).
- `FusedNode` — product of the composition pass; holds a composed R
  function ready for `jit()` and the members it was built from.

Passes are generics dispatched on node class:

```r
required_halo <- new_generic("required_halo", "node")
method(required_halo, FocalNode)  <- function(node) node@radius
method(required_halo, MapNode)    <- function(node) 0L
method(required_halo, ReduceNode) <- function(node) 0L
method(required_halo, SourceNode) <- function(node) 0L

fusable <- new_generic("fusable", "node")
method(fusable, MapNode)   <- function(node) TRUE
method(fusable, FocalNode) <- function(node) TRUE
method(fusable, Node)      <- function(node) FALSE   # default: barrier
```

Adding an op = new class + register methods. No central switchboard.

## Graph container

```r
Graph <- new_class("Graph", properties = list(
  nodes = class_environment   # id -> Node, plus ".next_id"
))
```

Environment-backed storage: O(1) id lookup, reference semantics for
cheap mutation during build/rewrite. Node objects themselves are immutable
S7 values; rewrites produce new nodes and swap env entries.

Rejected alternatives: `igraph` (attribute model too rigid, kept as
optional DOT export); `targets` (wrong abstraction — user pipelines vs
compiler IR); DAG-as-chained-mirai-promises (loses introspection and
replan ability).

## User-facing `LazyRaster`

```r
LazyRaster <- new_class("LazyRaster", properties = list(
  graph   = Graph,            # shared by reference
  node_id = class_integer,
  grid    = GridSpec          # cached for fast dim/crs access
))
```

Operators (`+`, `-`, `*`, `/`), methods (`focal()`, `reduce()`, `align()`,
`warp()`, `collect()`, `gradient()`) and subsetting (`[`) return new
`LazyRaster`s pointing at newly-added nodes in the same graph. Two
`LazyRaster`s derived from a common source share the graph, so the
`SourceNode` is literally shared — common subexpressions stay shared for
composition.

Rule of thumb: if a user has to type "node" or "graph" in normal use, the
layering is wrong.

## Planner passes

Run on `collect()`, in order:

1. **Validate** — grid/type compatibility on every binary op.
2. **Halo propagation** — reverse walk from sinks; accumulate required
   halo per edge; reset at `ReduceNode` and `WarpNode`.
3. **Compose** — collapse contiguous fusable runs into `FusedNode` holding
   a composed R function; halo = max of members; stop at barriers. XLA
   handles the actual fusion during `jit()`.
4. **Chunking** — pick physical chunk grid per stage, reconciling user
   hint, native GDAL block structure, halo, and worker RAM budget.
5. **Stage decomposition** — partition at barriers (`Reduce`, `Warp`,
   `Rechunk`).
6. **Device placement** — tag each stage with a device preference
   (`cpu`, `cuda`, `metal`) based on dtype, size, and daemon availability.
7. **Export** — `Plan` object (physical task graph, symbolic), plus
   `plot_plan()` via DOT / igraph.

## Executor

Physical task graph keyed by `(stage_id, chunk_idx)`. Each task:

1. Fetch inputs as `AnvilArray` on the stage's device. `Source` tasks read
   a GDAL window padded by the stage's halo and upload to the device;
   mid-graph tasks pull chunks + border strips from the producer's output
   store (or reuse co-located arrays).
2. Call the `jit()`-compiled kernel on padded inputs.
3. Trim halo; emit an `AnvilArray` output.

Scheduler: ready-queue. Tasks become runnable when all deps are `done`.
Dispatch via `mirai()`; callback marks `done` and enqueues newly-ready
successors.

### Halo exchange

- **Source halos**: free — enlarge the GDAL window.
- **Mid-graph halos**: producer writes chunk + border strips to a shared
  store (on-disk arrow/parquet initially; shared memory for same-host
  daemons later). Consumers fetch by key.
- **Halo > chunk size**: planner falls back to rechunking.

### Kernel cache

Per-daemon, keyed by `hash(composed_fn_source, input_dtypes, input_shapes,
device)`. anvil compiles once per unique kernel per daemon. Data locality
hint biases consumer placement toward the producer's daemon to keep halo
strips on the same device.

### Device-aware dispatch

mirai daemon pools are labelled by device (`cpu_pool`, `cuda_pool`,
`metal_pool`). The scheduler routes tagged stages to the matching pool.
CPU is the universal fallback.

## Differentiable pipelines

Because every kernel is jit-compiled via anvil, a whole `LazyRaster`
pipeline is a differentiable function. For a scalar-valued `loss`
expressible in terms of input `LazyRaster`s, `gradient(loss, wrt = ...)`
returns a callable that, on `collect()`, evaluates gradients via the same
chunked executor. Chunk-level autodiff composes through reductions by
linearity (sum of chunk-wise gradients = gradient of chunk-wise sum);
non-linear reductions require a combining-pass the planner emits.

Use cases: inversion problems, variational data assimilation, parameter
calibration, NN-style training over raster stacks.

## Relationship to vrtility

Replaces vrtility, but significant logic ports cleanly:

- STAC query → time-indexed stack construction.
- Mosaic/warp building via gdalraster VRT, now triggered by `WarpNode`.
- Collection-level alignment logic.

All of this lives in `Source` / `Warp` constructors and the STAC ingest
layer. The rest of the graph is unaware of VRT.

## Implementation plan

Phased so each stage is shippable and validates the previous one.

### Phase 0 — Scaffolding
Package skeleton, deps pinned (`S7`, `vaster`, `gdalraster`, `mirai`,
`anvil`), CI, `testthat`, lint. Name chosen.
**Exit**: `R CMD check` green on empty package.

### Phase 0.5 — anvil spike (throwaway)
Validate the assumptions anvil-first rests on, before committing the IR
to them. Specifically:
- Composed Map + Reduce in one `jit()` call.
- Focal / stencil patterns (neighbour indexing) in `jit()`.
- Efficient R-matrix ↔ `AnvilArray` ingress/egress at chunk scale.
- `gradient()` over a representative multi-stage composed function.
- Device selection under a mirai daemon.

**Exit**: one-page note documenting what anvil can and cannot express.
Feeds Phase 2's IR design.

### Phase 1 — Grid primitives
`GridSpec` + validators; `ChunkGrid` on top of vaster (chunk enumeration,
halo neighborhoods, block snapping). Cross-grid mapping (output chunk →
input window). 2D first, with hooks for time/band as outer dims.
**Exit**: property tests for pixel↔world round-trips, chunk coverage,
halo correctness at edges.

### Phase 2 — IR and graph
Node hierarchy, `Graph` container, generics (`required_halo`, `fusable`,
`is_barrier`, `output_grid`). `LazyRaster` with operators and basic
methods. No execution.
**Exit**: build a `Source → Map → Focal → Reduce` graph, inspect it,
correct `output_grid`s throughout.

### Phase 3 — Planner passes
Validate, halo propagate, compose, chunk, stage-decompose, device-place,
export. Plan visualization via DOT.
**Exit**: golden tests on toy pipelines; planner output matches
hand-traced plans.

### Phase 4 — GDAL IO
`SourceNode` → gdalraster windowed reads, returning `AnvilArray`.
`WarpNode` → lazy VRT via gdalraster. Convention translation isolated to
adapters.
**Exit**: `Source → Map` `collect()` matches reference
`terra` / `gdalraster` output, bit-exact within dtype tolerance.

### Phase 5 — Single-threaded, anvil-native executor
Topo-walk plan; fetch, jit-compile on first use, run, emit. Halo via
in-process env. Sink writes to disk (via gdalraster) or returns in
memory. No mirai yet.
**Exit**: end-to-end `Source → Focal(3×3) → Reduce(mean)` matches
reference; kernel cache working.

### Phase 6 — Differentiable pipelines
Wire `gradient()` through `LazyRaster`. Scalar-loss constraint on the
sink. Handle reductions (linear case first, combining-pass for general
case).
**Exit**: simple inversion problem (e.g. recover a convolution kernel
from inputs + outputs) converges.

### Phase 7 — Mirai distribution
Ready-queue scheduler on mirai daemons. Halo store (arrow-on-disk then
shared memory). Device-tagged pools. Locality hints. Back-pressure.
**Exit**: linear-ish scaling to N CPU cores; functioning GPU dispatch on
CUDA pool.

### Phase 8 — STAC / collections
Port vrtility's STAC ingest and mosaic logic as `Source` / `Warp`
constructors.
**Exit**: reproduce a representative vrtility workflow (e.g. median STAC
composite) end-to-end.

### Phase 9 — Ergonomics and polish
`print()` / `format()` / `str()` for `LazyRaster`, `[` subsetting,
named-dim accessors, vignettes, bench suite.

### Proof-of-concept scope
Phases 0.5 + 1 + 2 + 3 + 5 with gdalraster reading a real TIFF.
Single-threaded, anvil-native, working lazy raster with planner and JIT
kernels. If it clicks, the rest is execution engineering on known rails.

## Open questions

- **Package name.**
- **Minimum R version** (S7 + mirai + anvil implications).
- **License** (match vrtility / gdalraster).
- **CRS representation**: WKT2 vs proj string vs both. Hard to change later.
- **Focal op declaration**: do users declare `radius` explicitly, or does
  `focal()` enforce it? Kernel footprint cannot be inferred from an
  arbitrary R function.
- **Auto-rechunk policy**: when halo > chunk, do we silently rechunk or
  require the user to opt in?
- **Scaling target**: single-fat-host vs truly distributed. Both in scope;
  halo-store and scheduler tuning differ.
- **Expression surface inside `jit()`**: exact subset of R that anvil can
  trace. Spike must enumerate.
- **Focal stencil ergonomics**: whether anvil's indexing supports clean
  stencil expressions or whether we need a `stencil()` helper that
  expands to reshape + index patterns.
- **AnvilArray lifecycle**: allocator behaviour under high chunk
  throughput; need to avoid per-chunk GPU allocation storms.
