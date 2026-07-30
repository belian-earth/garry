# Execution architecture review: garry vs dask.distributed

Date: 2026-07-31 (deep review). Branch under review: `placement-pass`
(placement cost pass, pool affinity, per-plan pool shaping, cold-kernel
slow start, byte-budget admission against live RAM, writer daemon, f64
raw store). Reference: dask.distributed stable documentation
(distributed.dask.org / docs.dask.org), fetched 2026-07-30.

Ground truth read for garry: `R/scheduler.R` (whole file),
`R/placement.R`, `design/scheduling-review-2026-07-29.md`,
`design/placement-cost-pass.md`, `design/f64-store.md`,
`benchmarks/README.md` (2026-07-29 onward). dask citations name the doc
page; all quotes are from the stable docs, not blog or marketing
material.

## Verdict table

| Axis | Classification | One line |
|---|---|---|
| 1. Scheduling model | DIFFERENT-BY-DESIGN, one BEHIND sub-item | Static cost placement + byte admission vs dynamic occupancy scheduling; garry's real gap is daemon-identity routing, not stealing |
| 2. Memory management | Split: spill DIFFERENT-BY-DESIGN; measurement BEHIND | garry budgets on estimates corrected by live aggregate RAM; dask acts on measured per-worker process memory |
| 3. Resilience | BEHIND (deliberately, but one cheap adoption exists) | Fail-fast everywhere except `read_fail = "nodata"`; dask recomputes lost results and offers opt-in retries |
| 4. Graph optimization | AHEAD | garry fuses to single compiled XLA programs and prices placement; dask fusion is python-callable composition with no cost model |
| 5. Heterogeneity | DIFFERENT-BY-DESIGN, garry ahead on thread topology | Pool shaping/affinity is finer-grained than dask's static nthreads; dask's abstract resources solve a cluster problem garry does not have |
| 6. Observability | BEHIND | launch/done/write CSV vs task stream, per-worker memory panels, Prometheus |

The pattern across all six axes: dask is a general dynamic scheduler
that measures and reacts at runtime; garry is a domain-specific static
planner that models and admits at launch time. Where the workload is
known (raster windows, band structure, kernel FLOPs introspectable from
the IR), modelling beats reacting and garry is ahead. Where reality
diverges from the model (estimate drift, transient network failure,
daemon state), dask's measure-and-react machinery is exactly what garry
has been re-deriving one incident at a time: the crop=0 shm flood, the
24G-scope pin, the scan-compile OOM each added a reactive correction
(shm backstop, store_ok escape, cold surcharge) to an estimate-first
design. The adoption shortlist at the end targets that seam.

## 1. Scheduling model

**garry.** Placement is decided once per execution by a cost pass
(`R/placement.R:85-223`): per source->compute chain, fuse onto the read
fleet or materialise through the compute pool, from modelled FLOPs/px
(`.stage_flops_per_px`), shm movement bytes, pool thread widths, and
per-reader working-set bounds (`R/placement.R:134-184`). The drain is a
host polling loop (`R/scheduler.R:1744-1910`, 2 ms sleep, launch-scan
skipped when no harvest occurred, `R/scheduler.R:1735-1743`); admission
is by resident-store bytes for reads (`read_ok`,
`R/scheduler.R:1622-1625`), in-flight bytes plus cold-compile surcharge
for compute (`comp_ok` / `mb_eff`, `R/scheduler.R:1652-1661`), with
single-task escape hatches so an over-budget task serialises rather
than deadlocks. Task order is static: priority (fetches first), then
window-major so each window's cross-band input set becomes resident and
releasable as a unit (`R/scheduler.R:1572-1595`). Pool routing is
strict: no compute spill onto readers (`R/scheduler.R:1597-1604`).

**dask.** Priorities come from `dask.order` ("computing deeply before
broadly", critical-path aware), combined with a per-submission FIFO
counter; workers run LIFO locally (scheduling-policies.html). Worker
choice is dynamic: `worker_objective()` picks the worker that can start
soonest from occupancy (queued expected runtime) plus modelled transfer
time of dependencies; root-ish tasks are withheld on the scheduler and
released at `ceil(worker-saturation * nthreads)` per worker (default
1.1). Imbalance is corrected after the fact by work stealing: idle
workers take tasks from saturated ones when the compute-to-transfer
ratio justifies it, in ratio bins from >=8 down to 1/256
(work-stealing.html).

**Assessment: DIFFERENT-BY-DESIGN, with one genuine BEHIND.**

- *Work stealing is solved structurally, not missing.* mirai pools are
  anonymous task queues: any free daemon takes the next task, so
  within-pool load balance is automatic and there is nothing to steal.
  dask needs stealing because it first commits tasks to specific
  workers for locality; garry never commits, and recovers locality by
  fusion instead (the data never leaves the reader that produced it,
  `R/placement.R:130-143`). Same objective, opposite mechanism, and on
  a single machine with a POSIX-shm store the transfer term stealing
  prices is near zero anyway. Adopting stealing would be adopting a
  solution to a problem garry's store already dissolved.
- *Root-task withholding: garry is ahead for its domain.* dask
  withholds root tasks by count (worker-saturation); garry withholds by
  bytes against live RAM with window-major co-residency ordering. Byte
  admission is strictly more informative than task-count admission when
  task footprints span 10 MB masks to 2.4 GB fused MLP windows
  (`benchmarks/README.md:164-168`).
- *The BEHIND: daemon identity.* dask's scheduler knows each worker's
  state (data held, occupancy) and routes accordingly. mirai cannot
  route a task to a chosen daemon, and garry has paid for that three
  times: the warm-up broadcast must compile on every daemon rather
  than a warm subset (`R/scheduler.R:1158-1165`), a wide compute pool
  multiplies scan compiles because "mirai cannot route to warmed
  daemons" (`R/scheduler.R:646-658`, measured OOM at compute=10,
  `benchmarks/README.md:207`), and phase 9b rejected drain-time
  warm-up for the same reason (`benchmarks/README.md:373-379`). The
  cold-kernel slow start (`R/scheduler.R:1704-1712`, `1775-1777`) is a
  probabilistic workaround for what dask solves exactly.

**Adoption.** Directed routing would mean either per-daemon mirai
profiles (a pool of width 1 per daemon, host picks the profile) or an
upstream mirai feature. A width-1-profile experiment is cheap and would
let the scheduler send scan tasks only to daemons that have already
paid the compile, dissolving the slow-start ramp and making wide
compute pools viable for scan tails. Worth a spike; the fallback
machinery (slow start, surcharge) already exists if it costs too much
dispatch overhead. Full occupancy-based `worker_objective()` scheduling
is not worth it: with strict pools, byte admission, and anonymous
queues there is no imbalance left for it to fix.

## 2. Memory management

**garry.** Everything is an estimate priced before launch:
`.store_region_mb` (`R/scheduler.R:486-490`) for store residency,
`.stage_bytes_per_px` (`R/passes.R:861-889`) for task working sets
(with a /2 shared-input discount that deliberately excludes scan
stages, `R/scheduler.R:1145-1157`), `scan_compile_mb` as a
cold-compile surcharge (`R/scheduler.R:1225-1226`), and fused
working-set estimates from the placement pass
(`R/placement.R:194-207`). The correction loop is aggregate and
reactive: every 5 s the budgets re-derive from live available RAM
taken as min(host free, cgroup headroom) (`.garry_ram_avail_mb`,
`R/scheduler.R:450-457`; `refresh_mem_budgets`,
`R/scheduler.R:1514-1557`), clamped against actual /dev/shm free space
with a forced drop-flush on headroom breach
(`R/scheduler.R:1534-1543`). Store accounting is decremented at
queue-drop time while physical unlink lags on a flush clock bounded by
bytes and seconds (`R/scheduler.R:1279-1323`). There is no spill tier:
the profile-spill idea is measured-dead
(`design/scheduling-review-2026-07-29.md:143-150`), and the store IS
RAM (tmpfs), so "spilling" it to disk would just be materialising, the
thing the placement pass exists to avoid.

**dask.** Per-worker `memory_limit` with four thresholds acted on from
*measured* memory, polled every 200 ms: target 60% (spill LRU managed
data to disk), spill 70% of measured process memory (spill regardless
of sizeof estimates), pause 80% (stop starting tasks), terminate 95%
(nanny kills and restarts the worker) (worker-memory.html). dask
explicitly distinguishes managed (sizeof-tracked), unmanaged
(interpreter heap, fragmentation), and process (RSS) memory, because
its own estimates drift.

**Assessment: spill tiers DIFFERENT-BY-DESIGN; measured per-worker
memory BEHIND.**

- The spill/pause/terminate ladder solves out-of-core execution for
  arbitrary graphs. garry's answer is admission: never launch bytes
  that do not fit, with chunk sizing done by the planner. For a
  single-machine engine whose store is tmpfs, this is the right
  inversion, and the SI crop=0 result (completes at 32.8 GB peak in a
  42 G scope, `benchmarks/README.md:182`) shows the admission model
  now holds under its hardest known load.
- But dask's core insight stands against garry: *estimates drift, so
  act on measurement*. Every recent garry defect on this axis was an
  estimate wrong in one direction: `store_mb = 0` compute outputs,
  fused regions over-charged 145x, f64 booked at half size, edge
  chunks at 8 B/px against a 4 B/px booking
  (`design/scheduling-review-2026-07-29.md:91-112`,
  `design/f64-store.md:36-42`). Each was found by an OOM or a stall,
  then fixed in the model. garry has aggregate measurement (RAM,
  cgroup, shm df) but zero per-daemon measurement: nothing today would
  notice one daemon's RSS at 16.5 GB during a scan compile
  (`benchmarks/README.md:199-201`) except the machine-wide free-RAM
  dip, attributed to nobody.
- dask's pause threshold has a garry analog already (budgets tighten
  as available RAM shrinks, which stops launches); terminate/nanny has
  none, and none is needed while runs are fail-fast.

**Adoption.** A per-daemon RSS poll (`/proc/<pid>/status`, the pids
are already collected for affinity at `R/scheduler.R:539-543`) folded
into `refresh_mem_budgets` as a correction term: when measured fleet
RSS exceeds the modelled in-flight bytes by more than a slack factor,
shrink `comp_budget_mb` by the excess. That is dask's
managed-vs-process distinction transplanted into the admission model,
~30 lines, no new processes, and it converts the next estimate defect
from an OOM into a throughput dip plus a log line. Worth doing;
per-task measured `sizeof` feedback (dask's other half) is not, since
region sizes are exact by construction (byte payloads with known
dims), unlike dask's arbitrary Python objects.

## 3. Resilience

**garry.** Fail-fast: any daemon task error aborts the run
(`R/scheduler.R:1813-1825`), a writer-daemon failure aborts
(`R/scheduler.R:1693-1695`), and a daemon death surfaces as a mirai
error with no recovery. Two deliberate nets exist: fetch failures
under `garry.read_fail = "nodata"` write an all-nodata placeholder
window so the mosaic reads a hole (`R/scheduler.R:233-249`), and the
`garry_jit_miss` path re-sends a task once with its full closure when
a daemon's jit cache is cold (`R/scheduler.R:1815-1824`). The
scheduling review lists "no retry machinery for cloud reads" as a
known debt (`design/scheduling-review-2026-07-29.md:136-137`).

**dask.** Worker failure: the scheduler holds "a full history of how
each result was produced" and recomputes lost results on surviving
workers; the nanny restarts dead worker processes; unresponsive
workers are declared dead after ~3 s (resilience.html). Scheduler
failure loses everything ("no persistence mechanism"), same as garry's
host. User exceptions are NOT retried by default; `retries=` on
submit/compute is opt-in and defaults to 0 (api.html).

**Assessment: BEHIND, deliberately, with one adoption that is nearly
free.**

- The popular claim that dask retries failures by default is false:
  its default for task errors is garry's behaviour (surface the
  exception). The real gaps are (a) transient-error retry as an
  *option* and (b) surviving worker death. For a single-machine
  engine, (b) is low value: daemons share the host's fate, and the
  observed daemon deaths (XLA teardown segfaults,
  `benchmarks/README.md:120-122`) happen after results return.
- (a) is high value and the mechanism already exists. Cloud reads
  (fetch tasks, direct remote reads) fail transiently by nature;
  today's choices are abort-the-run or silently-nodata. The jit-miss
  resend is a working precedent for "harvest an error, classify,
  relaunch once" inside the drain loop. Reads and fetches are
  idempotent by construction (pure window reads keyed by task), so
  retry is safe.

**Adoption.** `garry.read_retries` (default 1 or 2): in the harvest
error branch (`R/scheduler.R:1813-1825`), when the failed task's pool
is read/fetch and the error is not a garry-classed planning error,
relaunch up to N times before either aborting or falling through to
the nodata placeholder. ~20 lines, closes the catalogued debt, and
makes `read_fail = "nodata"` the second net instead of the only one.
Provenance-based recomputation of lost store regions (dask's worker
recovery) is not worth building until daemons die mid-task in
practice; the refcount/provenance tables (`task_ins`, `task_stage_of`)
would support it if that day comes.

## 4. Graph optimization

**garry.** Planner passes over a typed S7 IR: stage-merge folds
single-consumer chains into one stage that jits to ONE XLA program per
chunk (172 members in the benchmark composite,
`benchmarks/README.md:358-367`); reduce boundaries deliberately break
fusion so per-band tails overlap the next band's drain
(`benchmarks/README.md:295-303`); content-addressed kernel signatures
collapse structurally identical stages to one compile
(`R/scheduler.R:352-407`); band coalescing merges per-band reads; and
the placement cost pass decides fuse-vs-materialise per chain at
execute time from runtime resources (`R/placement.R:85-223`) with a
public explain surface (`garry_explain_placement`,
`R/placement.R:245-259`). Culling is inherent: plans are built from
requested sinks over a lazy graph, and warp-only sources are skipped
(`R/scheduler.R:892-901`).

**dask.** `cull` (drop tasks not needed for requested keys), `inline`,
and `fuse` of linear chains so "the scheduler run[s] all of these on
the same worker to reduce data serialization"; specialized automatic
variants per collection; HighLevelGraphs keep layers unmaterialized so
optimization and transmission scale past millions of tasks
(optimize.html, high-level-graphs.html). Notably, enabling resource
annotations requires *disabling* fusion
(`optimization.fuse.active: False`, resources.html): dask's fusion and
its placement expressiveness fight each other.

**Assessment: AHEAD.** Three structural reasons:

1. dask fusion composes Python callables; garry fusion produces a
   single compiled XLA kernel, i.e. it optimizes below the task
   boundary where dask cannot see.
2. dask has no cost model anywhere in optimization or scheduling
   beyond the stealing ratio; garry's placement pass prices FLOPs,
   movement, thread width, and working sets against live pool shapes,
   and validated the model on a real pipeline (predict 551 s -> 175 s
   at crop=2048, `benchmarks/README.md:176-181`).
3. garry's fusion and placement compose (fusion IS a placement
   outcome); dask's fusion and annotations conflict by documentation.

The one dask idea worth watching is HLG's refusal to materialize
low-level graphs. garry materializes every stage and task
(`R/scheduler.R:909-919`), already engineering around O(n^2) hazards
at ~2e4 tasks (env-based task table, O(1) readiness,
`R/scheduler.R:1714-1720`). At 10x current plan sizes the task build
itself becomes the bottleneck; the catalogued host-critical-path debts
(`design/scheduling-review-2026-07-29.md:126-134`) are the cheaper
first response, so no action now.

## 5. Heterogeneity

**garry.** Two typed pools with distinct roles (read/compute, plus one
writer daemon, `R/scheduler.R:669-677`), per-daemon disjoint CPU
affinity applied at creation so any XLA client anywhere is narrow
(`.pool_affinity_apply`, `R/scheduler.R:533-553`), per-plan re-shaping
in milliseconds (scan plans get half-machine masks, kernel fleets keep
narrow ones, `.comp_pool_shape`, `R/scheduler.R:566-576`, invoked per
execution at `R/scheduler.R:950-956`), device tags on stages (GPU
compute never fuses, `R/placement.R:60`), and thread width as a priced
placement dimension (spike A/B, `benchmarks/README.md:103-141`).

**dask.** Abstract worker resources (`--resources "GPU=2"`), task
requirements via `resources=` or `dask.annotate`, enforced by the
scheduler with a no-worker wait state; resources are opaque labels the
scheduler only counts (resources.html). Worker nthreads is fixed at
worker start; there is no dynamic re-shaping and no notion of CPU
affinity.

**Assessment: DIFFERENT-BY-DESIGN; garry is ahead on the axis that
matters to it.** dask's resources solve cluster heterogeneity (which
machine has the GPU); garry's problem is intra-machine thread topology
(how wide is each XLA client), which dask cannot express at all: its
thread count is static per worker for the process lifetime, while
garry re-masks pools per plan. The measured wins (2 fat vs 10 narrow
by workload, `benchmarks/README.md:195-224`) come precisely from that
expressiveness. What garry lacks from dask is a *user-facing* per-op
annotation ("this custom reducer needs X"), but every concrete need so
far became a modelled term instead (scan compile surcharge, fused
working sets), which is stronger than asking the user. Adopt nothing
now; if opaque user kernels whose costs cannot be introspected become
common, a `lazy_map(resources=)` escape valve mapping to the admission
budget is the shape to build, and it slots into `add_task`'s existing
`mb`/`cold_mb` fields (`R/scheduler.R:911-919`) without scheduler
changes.

## 6. Observability

**garry.** `garry.task_log`: a CSV of `(time, event, task_key)` for
launch/done/write plus drain_end/host_end markers
(`R/scheduler.R:1726-1730`, `1915-1917`), a 5 s progress line
(`R/scheduler.R:1903-1908`), and `garry_explain_placement()` for
placement decisions (`R/placement.R:245-259`). It has earned its keep
(the phase 9b gap decomposition and the flood diagnosis both came from
it, `benchmarks/README.md:349-352`), but it records neither which
daemon ran a task, nor bytes, nor queue-wait vs run time; the
pool-topology memory work needed ad hoc external per-PID tracing
(`benchmarks/README.md:195-201`).

**dask.** Live dashboard on :8787: task stream (per-thread Gantt with
transfer/spill/serialization coloring), per-worker memory with
threshold coloring, occupancy, bandwidth, progress by task prefix
(dashboard.html); Prometheus `/metrics` on scheduler and workers
(task counts, memory breakdown, spill I/O, GIL contention, event-loop
tick times, prometheus.html); `performance_report()` for a shareable
post-hoc HTML bundle (api.html).

**Assessment: BEHIND.** This is the least contested axis: dask's
observability is what lets its users see exactly the classes of
problem garry has been diagnosing with one-off instrumentation
(estimate drift, per-worker memory attribution, drain stalls). A live
dashboard is not the right adoption for a single-machine R engine that
runs minutes-long batch jobs; a richer log plus a post-hoc report is.

**Adoption.** Two steps, both cheap:

1. Widen the task log: add daemon pid (returnable from the task body
   for one integer), pool/slot, `store_mb`/`mb_live`, and a
   ready-timestamp so queue-wait separates from run time. The write is
   already one `cat` per event; three more columns cost nothing.
2. A `garry_perf_report(task_log)` that renders the CSV into the two
   plots that answer 90% of questions: a per-daemon task-stream Gantt
   (dask's task stream) and modelled-resident-bytes vs measured
   RAM/shm over time (which would have shown the crop=0 flood as a
   diverging pair of lines instead of an OOM). If the per-daemon RSS
   poll from axis 2 lands, its samples belong in the same log.

## Adoption shortlist (ranked)

1. **Transient read/fetch retry** (axis 3): ~20 lines on the
   jit-miss-resend pattern; closes a catalogued debt; makes cloud runs
   survivable without silently widening nodata.
2. **Per-daemon measured RSS as a budget correction** (axis 2): dask's
   one structural advantage on memory, transplanted into the admission
   model; turns the next estimate defect into a log line, not an OOM.
3. **Task-log columns + post-hoc perf report** (axis 6): the
   measurement substrate for 2, and the standing answer to "where did
   the time/memory go" that every deep review has rebuilt by hand.
4. **Width-1-profile routing spike** (axis 1): tests whether directed
   dispatch dissolves the cold-compile ramp and reopens wide scan
   pools; keep only if dispatch overhead stays negligible.

Explicitly not worth adopting: work stealing (dissolved by anonymous
queues + shm store), spill-to-disk tiers (admission-first design,
measured-dead), pause/terminate nannies (fail-fast is correct for
batch runs), abstract resources (no cluster heterogeneity to
describe), adaptive scaling (pool width is slots, admission is
concurrency: idle narrow daemons are already near-free), live
dashboard (batch, single machine), and HLG-style lazy graph
materialization (wrong scale by ~10x, and the host critical path has
cheaper known fixes first).
