# garry's daemon pools on mizu

Status: built on branch `mizu-pools`, 2026-11-06, on `plan-reads` (#55) with `host-open-ingest` (#56) merged. It replaces mirai as the transport for garry's daemon pools. The A/B section compares it with that same base commit (`c63c96e`) on mirai.

## What mizu is

mizu 0.1.0 (Charlie Gao, CRAN 2026-11-05) runs R worker processes on one machine and moves tasks and results through POSIX shared memory (Win32 file mappings on Windows) instead of sockets:

- **Pools.** `mizu_pool(n)` creates a shared region holding a lock-free injection ring for each submitter, a work-stealing deque for each worker and a table of result slots. Workers are `Rscript` processes that join by a token. A pool has no dispatcher process: a submit is one shared-memory write plus at most one wake-up.
- **Submit and collect.** A task is an expression and named arguments. A result past a slot's inline budget travels in a region of its own and arrives as a view. A `mori::share()` object crosses as its name, as it does through mirai. `mizu_collect(t, timeout = 0)` returns the `mizu_timeout` sentinel while a task runs, and a handle can be collected once.
- **Failures.** A task's own error is re-raised at collect with its classes and fields (cli's `body` included). A worker that dies fails only the tasks it had claimed, seen in about 6 ms through a kernel-released lock, with no heartbeat. A task queued on a dead single-worker pool never runs.
- **Cancel.** `mizu_cancel()` skips a queued task and lets a running one finish, discarding its result. A cancelled task's slot is freed when it ends, so it can never be collected afterwards.
- **What it lacks for garry.** It has no `everywhere()` and no way to address one worker of a pool: work is stolen between workers.

Measured on the workstation (20 threads):

| | mizu | mirai |
|---|---|---|
| spawn and join, 1 / 6 / 20 workers | 0.10 / 0.14 / 0.26 s | 0.13 / 0.18 / 0.35 s |
| 256 MB raw result | 0.13 s | 0.42 s |
| a non-blocking collect | 1 µs | |

## How garry maps onto it

garry needs to reach each daemon: readers pin the store regions their tasks create until the host drops them, every daemon takes setup and run-start broadcasts, and compute routing depends on which daemon holds which kernel (design/routed-dispatch.md). A work-stealing pool cannot give that. So every garry daemon is a mizu pool of one worker (`R/tasks.R`):

| garry | mirai | mizu |
|---|---|---|
| `garry_read` | one profile, dispatcher in the host | a group of N single-worker pools, routed on the host |
| `garry_comp_<i>` | a width-1 profile, no dispatcher | a single-worker pool |
| `garry_write` | a width-1 profile | a single-worker pool |
| broadcast | `everywhere()` | one task to each member |
| cancel | `stop_mirai()`, interrupting a running task (garry resumed through it) | `mizu_cancel()`, which never interrupts |
| lost daemon | error value 19, or a wait that never ends | `mizu_error_worker_died`, a slot reported free, or (Linux) its process gone |

- **The reader group.** The host holds a group's tasks until a reader has fewer than two running or queued, the least loaded first. A task lands as soon as it is polled, and the next queued one goes out then. This matches what the dispatcher did with the scheduler's cap of two reads a reader, except that a task queued behind a long read cannot move to an idle reader. Every wait pumps the groups, so queued reads go out whichever handle the host waits on.
- **A daemon's backlog.** mizu bounds what one daemon holds: past its result slots a submit fails at once, and past its ring a submit blocks. mirai's queues had no bound, and three callers rely on that: the sink's writes (bounded by bytes, not count), the read-only route's writes (two a reader, more than 128 past 64 readers), and the store's drops, which pile up behind a long compile. So past `.member_cap` (48) tasks out on one daemon, the rest wait on the host in the daemon's own backlog, in order, and go out as its tasks land. Order on a daemon is what the warm-ups, the writer's close and the failure path's sync before its clear rely on, and a backlog keeps it.
- **Handles.** A garry handle is an environment: `state` (`queued`, `launched` or `done`) and `data`. Failure values are `garry_task_raised`, which holds the daemon's condition, and `garry_task_lost`, which says why: the daemon died, the task was cancelled, or its pool closed. They replace mirai's `miraiError` and `errorValue`, and `.task_failure()` and `.task_abort()` read them.
- **Start.** `.pools_start()` spawns every daemon of a generation at once with `inst/scripts/garry-daemon.R`, which loads mizu, writes its pid and waits for its pool's token, and only then creates the pools, one by one. `mizu_pool()` blocks until its worker joins, so created one after another, 27 pools took 2.8 s; with the workers already started they take 0.37 s. The daemons get the host's library paths (covr's instrumented library left out, as before), garry's malloc thresholds and `GLIBC_TUNABLES` (below).
- **Close.** `.pools_close()` stops the pools, which cancels everything they hold. Each daemon exits once it has finished what it runs. The close finds its daemons by the pid files they wrote, waits for them to exit, names them by pool after 3 s, and SIGKILLs them at 60 s or on a Ctrl-C. Results not yet collected are lost; the old close let queued tasks run and waited for every reply, but only because closing under a reply could hang R (NNG's IPC race). That race, the broadcast wedge (design/mirai-broadcast-wedge.md) and the checks written for them are gone.

## Traps

- **malloc.** A mizu worker calls `mallopt()` at start, raising glibc's mmap threshold to 32 MB and its trim threshold to 128 MB, which would override garry's `MALLOC_*_THRESHOLD_=131072` and keep daemons resident at their peak. It skips that when `GLIBC_TUNABLES` tunes malloc, so garry sets its thresholds there for the daemons (`.daemon_env()`).
- **Cancel then collect.** A cancelled task must land at the cancel: once a running one ends, its slot is freed, and a collect raises "task handle already collected".
- **A closed pool.** Collecting a task of a stopped pool raises "pool handle is closed", so a handle of a closed generation lands as lost without asking mizu.
- **A cancel too late.** `mizu_cancel()` returns `FALSE` for a task that has finished, which then holds its slot, and a large result its shared memory, until collected; the cancel collects it at once.
- **Ctrl-C.** Daemons share the host's process group, so a Ctrl-C at its terminal interrupts them too. mizu's worker loop catches errors only and turns interrupts back on to run a task, so an interrupt mid-task ended the daemon: the read it ran failed as lost and the pool went down (measured: SIGINT to the group, 3 of 4 daemons left, the busy one gone; mirai's daemons all survived). Every task runs through `.daemon_resumable()`, which resumes through an interrupt, and the worker's own loop runs under `suspendInterrupts()`; now all 4 survive and the busy task finishes. The wrapper is garry's, so a fresh daemon's first task loads garry: `garry_daemons()` takes pids from the daemons' pid files, as probing each profile in turn cost a garry load each (8.5 s against 3.6 s for the default fleet).
- **Death watch.** mizu sees a worker die through `pidfd_open()` on Linux; where that is missing or refused it sees nothing, and a task the worker was running never resolves. garry checks each daemon's process in `/proc` with the once-a-second width check, so a wait still ends.
- **Windows.** garry reads no command line there, so a close cannot watch its daemons exit; each pool's stop waits for its worker instead, up to the close's 60 s.
- **Rings.** One submitter, rings of 64 entries and 128 result slots of 4 KB: 1 MB of shared memory a daemon, 27 MB for the default fleet on 20 threads (54 MB at twice the size). `.member_cap` keeps a daemon's ring from filling.

## Spin-up

Profiled on base, `garry_daemons()` with 20 readers, 6 compute daemons and the writer took 4.4 s: 1.2 s in eight `mirai::daemons()` calls, 3.0 s in the first broadcast, where 27 processes load garry at once, and 0.1 s in pid probes, read setup and affinity. One `library(garry)` costs 0.9 s, of which 0.59 s is gdalraster's shared libraries (93 of them). mizu shortens only the first part.

## A/B against mirai

Same workstation (20 threads, 62 GB), base commit `c63c96e` on mirai against this branch, each installed into a library of its own. Runs interleaved, nothing else heavy on the machine.

**Benchmark suite** (`benchmarks/run.py bench`, arms `garry` (this branch) and `garry-base`, every task and variant, cold and warm):

| | small, 3 reps | medium, 2 reps |
|---|---|---|
| wall, geometric mean of mizu / mirai over 20 phases | 1.004 (0.95 to 1.09) | 1.010 (0.97 to 1.04) |
| startup (process start to ready, pools included), median | 4.68 s against 5.53 s | 4.61 s against 5.48 s |
| whole-run memory.peak, median difference | +123 MB | +19 MB (most runs sit at the 16 GB cap) |
| outputs | byte-identical, every task | byte-identical, every task |

A one-repeat small run of the final branch, after the review's fixes, gave a geometric mean of 0.999 and a 4.61 s start against 5.50 s.

Medium leans 1 % slower, 14 of its 20 phases above 1.0, most within the spread of a run: median on warped reads, the largest at +0.7 s, took 28.0 to 29.9 s cold over four further runs of this branch, against base's 29.1 s. Forcing the reader group's depth to 1 instead of 2 changed nothing there (28.0 and 29.7 s against 29.9 and 28.9 s), so the reads that queue behind a running one are not the cause.

**Pools** (`garry_daemons()` defaults: 20 readers, 6 compute daemons, the writer):

| | mirai | mizu |
|---|---|---|
| processes up and joined | 1.2 s (eight `mirai::daemons()` calls) | 0.37 s |
| `garry_daemons()` | 4.4 to 4.6 s | 3.7 s |
| close | 1.6 s | 0.03 s |
| idle daemon, anonymous memory | 120.6 MB (reader) | 124.5 MB |
| `/dev/shm` for the fleet | 0 | 27 MB |
| full test suite, 4 workers, two interleaved runs each | 209.7, 208.0 s | 179.5, 179.8 s |

**Transfers.** Five tiny collects and five small writes cost the same (1.33 s and 1.72 s either way), so garry's per-run floor is not the transport. Collecting 55 medium HLS dates of one band into an R array (737 M cells, 2.9 GB of f32 crossing to the host) took a median 2.85 s against 2.94 s over eight interleaved runs each; in both the host's copy sets the pace, results waiting 0.6 to 0.7 s on average to land. A single 256 MB result is 3 times faster on mizu, but garry's reads land in pieces the host copies one at a time.

## Review

An agent reviewed the branch before the PR. It found the per-daemon bounds (fixed with the backlog), the Ctrl-C regression (confirmed by sending SIGINT to the host's process group: 3 of 4 daemons survived on mizu against 4 of 4 on mirai; fixed, now 4 of 4), the death watch's dependence on `pidfd_open()`, the Windows close, a late cancel's held slot and a failed send's stranded handle, all fixed with tests. Its report that mizu's misuse errors read as a task's own failure did not hold: they are classed `mizu_error`, which `.task_collect()` raises.

