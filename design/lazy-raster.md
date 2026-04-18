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
with an R-native lazy array abstraction. Compute runs through JIT-compiled
kernels (`anvil`). Grid geometry is handled in pure R using `vaster`.

This maps closely to xarray + dask + rioxarray, but with spatial awareness
as a first-class property of the lazy array rather than metadata bolted on.

## Architectural layers

Four layers, each with one job:

1. **User API (`LazyRaster`)** — array-like, CRS/transform-aware, composes
   lazily. Users never see nodes or graphs.
2. **IR (`Graph` + `Node`)** — a logical DAG of operations. Built by the
   user API; consumed by the planner.
3. **Planner** — passes that validate, propagate halos, fuse kernels, pick
   chunk grids, and emit a physical task graph.
4. **Executor** — a ready-queue scheduler that dispatches chunk tasks via
   `mirai`, calls JIT kernels from `anvil`, and handles halo exchange.

## Foundations

| Package      | Role                                                          |
|--------------|---------------------------------------------------------------|
| `vaster`     | Pure grid math: pixel↔world, extent/dim snapping, cell index. |
| `gdalraster` | GDAL bindings: windowed reads, VRT construction, writing.     |
| `anvil`      | JIT compilation of fused R expressions into per-chunk kernels.|
| `mirai`      | Daemons and dispatch for distributed chunk-task execution.    |
| `S7`         | Object system for IR nodes and user types.                    |

Convention boundary: vaster coords are the internal language. gdalraster
adapters translate at IO. GDAL's 0-based conventions do not leak into the
middle of the graph.

## Grid and alignment model

A `GridSpec` is a typed, validated object:

```r
GridSpec <- new_class("GridSpec", properties = list(
  crs       = class_character,
  transform = class_numeric,   # length 6
  extent    = class_numeric,   # xmin, ymin, xmax, ymax
  dim       = class_integer,   # nx, ny, (nt, nb optional)
  dtype     = class_character
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
- `FusedNode` — product of the fusion pass; carries member nodes + halo.

Passes are generics dispatched on node class, e.g.:

```r
required_halo <- new_generic("required_halo", "node")
method(required_halo, FocalNode)  <- function(node) node@radius
method(required_halo, MapNode)    <- function(node) 0L
method(required_halo, ReduceNode) <- function(node) 0L
method(required_halo, SourceNode) <- function(node) 0L

fusable <- new_generic("fusable", "node")
method(fusable, MapNode)    <- function(node) TRUE
method(fusable, FocalNode)  <- function(node) TRUE
method(fusable, class_any)  <- function(node) FALSE
```

Adding an op = new class + register methods. No central switchboard.

## Graph container

```r
Graph <- new_class("Graph", properties = list(
  nodes   = class_environment,   # id -> Node, O(1) lookup
  next_id = class_integer
))
```

Environment-backed storage for O(1) lookup; immutability is preserved at
the node level (rewrites produce new nodes, swap env entries).

Rejected alternatives:

- `igraph` as storage: attribute model too rigid; graph gets rebuilt on
  every pass; kept as an optional debug export.
- `targets`: wrong abstraction (user pipelines vs compiler IR).
- DAG-as-chained-promises via mirai: loses introspection and replan ability.

## User-facing `LazyRaster`

```r
LazyRaster <- new_class("LazyRaster", properties = list(
  graph   = Graph,            # shared by reference
  node_id = class_integer,
  grid    = GridSpec          # cached for fast dim/crs access
))
```

Operators (`+`, `-`, `*`, `/`), methods (`focal()`, `reduce()`, `align()`,
`warp()`, `collect()`), and subsetting (`[`) return new `LazyRaster`s
pointing at newly-added nodes in the same `Graph`.

Two `LazyRaster`s derived from a common source share the graph, so the
`SourceNode` is literally shared — common subexpressions stay shared for
fusion.

Rule of thumb: if a user has to type "node" or "graph" in normal use, the
layering is wrong.

## Planner passes

Run on `collect()`, in order:

1. **Validate** — grid/type compatibility on every binary op.
2. **Halo propagation** — reverse walk from sinks; accumulate required
   halo per edge; reset at `ReduceNode` and `WarpNode`.
3. **Fusion** — collapse contiguous `Map` / `Focal` runs into `FusedNode`;
   halo = max of members; stop at barriers.
4. **Chunking** — pick physical chunk grid per stage, reconciling user
   hint, native GDAL block structure, halo, and worker RAM budget.
5. **Stage decomposition** — partition at barriers (`Reduce`, `Warp`,
   `Rechunk`).
6. **Export** — `Plan` object (physical task graph, symbolic), plus
   `plot_plan()` via DOT / igraph.

## Executor

Physical task graph keyed by `(stage_id, chunk_idx)`. Each task:

1. Fetch inputs. `Source` tasks read a GDAL window padded by the stage's
   halo; mid-graph tasks pull chunk + border strips from the producer's
   output store.
2. Call the fused JIT kernel (from `anvil`) on padded inputs.
3. Trim halo; emit output.

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

Per-daemon, keyed by `hash(fused_expression, dtypes, halo)`. Anvil
compiles once per unique kernel per daemon. Data locality hint biases
consumer placement toward the producer's daemon to keep halo strips
in-process.

## Relationship to vrtility

This package replaces vrtility, but significant logic ports cleanly:

- STAC query → time-indexed stack construction.
- Mosaic/warp building via gdalraster VRT, now triggered by `WarpNode`.
- Collection-level alignment logic.

All of this lives in `Source` / `Warp` constructors and the STAC ingest
layer. The rest of the graph is unaware of VRT.

## Implementation plan

Phased so each stage is shippable and validates the previous one.

### Phase 0 — Scaffolding
Package skeleton, deps, CI, `testthat`, lint. Name chosen.
**Exit**: `R CMD check` green on empty package.

### Phase 1 — Grid primitives
`GridSpec` + validators; `ChunkGrid` on top of vaster (chunk enumeration,
halo neighborhoods, block snapping). Cross-grid mapping (output chunk →
input window). 2D first, with hooks for time/band as outer dims.
**Exit**: property tests for pixel↔world round-trips, chunk coverage,
halo correctness at edges.

### Phase 2 — IR and graph
Node hierarchy, `Graph` container, generics (`required_halo`, `fusable`,
`output_grid`, `validate_grid`). `LazyRaster` with operators and basic
methods. No execution.
**Exit**: build a `Source → Map → Focal → Reduce` graph, inspect it,
correct `output_grid`s throughout.

### Phase 3 — Planner passes
Validate, halo propagate, fuse, chunk, stage-decompose, export. Plan
visualization via DOT.
**Exit**: golden tests on toy pipelines; planner output matches
hand-traced plans.

### Phase 4 — GDAL IO
`SourceNode` → gdalraster windowed reads. `WarpNode` → lazy VRT via
gdalraster. Convention translation isolated to adapters.
**Exit**: `Source → Map` `collect()` matches reference `terra`/`gdalraster`.

### Phase 5 — Single-threaded executor
Topo-walk plan; fetch, run, emit. Halo via in-process env. Sink writes
disk or returns memory. No mirai, no anvil.
**Exit**: end-to-end `Source → Focal(3×3) → Reduce(mean)` bit-exact vs
reference.

### Phase 6 — Anvil kernel compilation
Compile `FusedNode` via anvil; cache per daemon; fallback to interpreted R.
**Exit**: 5–20× speedup on a fused Map-heavy pipeline vs Phase 5.

### Phase 7 — Mirai distribution
Ready-queue scheduler on mirai daemons. Halo store (arrow-on-disk then
shared memory). Locality hints. Back-pressure.
**Exit**: linear-ish scaling to N cores on a Focal pipeline; no deadlock
under memory pressure.

### Phase 8 — STAC / collections
Port vrtility's STAC ingest and mosaic logic as `Source`/`Warp`
constructors.
**Exit**: reproduce a representative vrtility workflow (e.g. median STAC
composite) end-to-end.

### Phase 9 — Ergonomics and polish
`print()` / `format()` / `str()` for `LazyRaster`, `[` subsetting, named-dim
accessors, vignettes, bench suite.

### Proof-of-concept scope
Phases 1 + 2 + 3 + 5 with gdalraster stubbed by reading a real TIFF.
Single-threaded, non-JIT, working lazy raster with planner. If it clicks,
the rest is execution engineering on known rails.

## Open questions

- **Package name.**
- **Minimum R version** (S7 + mirai implications).
- **License** (match vrtility / gdalraster).
- **CRS representation**: WKT2 vs proj string vs both. Hard to change later.
- **In-memory backend**: base R array, `nanoarrow`, or `torch`? Affects
  anvil interop and zero-copy potential.
- **Focal op declaration**: do users declare `radius` explicitly, or do we
  provide a `focal()` wrapper that enforces it? Kernel footprint cannot be
  inferred from an arbitrary R function.
- **Auto-rechunk policy**: when halo > chunk, do we silently rechunk or
  require the user to opt in?
- **Scaling target**: single-fat-host vs truly distributed. Both are in
  scope but the halo-store and scheduler tuning differs.
