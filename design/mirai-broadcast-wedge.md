# A lost daemon wedges a mirai dispatcher

Seen on mirai 2.7.2 and nanonext 1.10.2, 2026-10-31. Not yet reported upstream.

Kill a daemon that is busy when `everywhere()` queues a task for it, and the
dispatcher stops assigning work. The survivors stay connected and idle, the
queued task stays queued, and every later task queues behind it. Cancelling the
queued task with `stop_mirai()` frees nothing. Only `daemons(0)` ends it.

```r
library(mirai)
daemons(3, .compute = "w")
f <- tempfile()
busy <- mirai({ writeLines(as.character(Sys.getpid()), f); Sys.sleep(300) }, f = f, .compute = "w")
while (!file.exists(f) || !length(readLines(f))) Sys.sleep(0.05)
sent <- everywhere(Sys.getpid(), .compute = "w")
Sys.sleep(1)
tools::pskill(as.integer(readLines(f)), tools::SIGKILL)
Sys.sleep(2)
status(.compute = "w")$connections # 2
status(.compute = "w")$mirai       # awaiting 1, executing 0, completed 3
m <- mirai(1 + 1, .compute = "w")
Sys.sleep(5)
unresolved(m)                      # TRUE: two idle daemons never take it
status(.compute = "w")$mirai       # awaiting 2, executing 0, completed 3
daemons(0, .compute = "w")
```

## Why garry meets it

A run's region drops are broadcasts on the read pool, sent while readers are
busy. A reader killed for memory at that moment left the pool alive by the check
garry had then, which asked only for one connected daemon, so each later wait
spun forever.

## How garry ends the wait

Two checks run at a run's start and once a second in every wait
(`.idle_step()` in `R/pools.R`). Neither closes a pool from inside the wait;
`garry_daemons()` restarts it.

- `.assert_pools_alive()` holds every pool to the width `garry_daemons()`
  started it with. A pool with fewer connections fails the run with a
  `garry_pool_error` naming it and its count.
- `.assert_pools_moving()` fails a dispatcher with tasks queued, none running
  and none finished across two checks a second or more apart, at full width.
  It marks the pool stuck, so every later run fails at its start.

When a queue stops with no daemon running, from `dispatcher.c` (identical in
nanonext 1.10.2 and 1.10.4):

- `status()$connections` is the dispatcher's `outq_count`. It counts daemons
  past their init message and falls only in `dispatch_remove_daemon()`, on a
  disconnect or a daemon's last reply. garry's daemons never send a last reply
  (no `maxtasks`, `idletime` or `walltime`), and `garry_daemons()` returns only
  once all of them have connected.
- `everywhere()` sends one task per connection it reads then: N-1 sync tasks
  and an unsynced final one. While a generation lasts,
  `dispatch_find_idle_daemon()` skips every daemon that took a sync task of it,
  for any task. Only the assignment of an unsynced task ends the generation.
- The queue drains in order, under the same lock as every event that frees a
  daemon (`dispatch_init_cb()`, a reply in `dispatch_handle_daemon_recv()`). A
  queued task with an eligible idle daemon is never visible to `status()`.
- `awaiting > 0, executing == 0` therefore means every connected daemon took a
  sync task of the current generation, and no unsynced task came to end it.

That happens two ways [I from `dispatcher.c`, M for each below]:

1. **A daemon is lost.** One broadcast puts N-1 daemons in its generation, and
   its final task waits for the one that took none. If that daemon dies first,
   every survivor is in the generation and the final task can never go. The pool
   is below its width, which the width check reads.
2. **A generation is left open with no daemon lost.** Its final task never
   reaches a daemon: it is cancelled with `stop_mirai()` while queued, or
   `everywhere()` is cut by an interrupt or a time limit after its sync tasks
   went out. The next broadcast's sync tasks join that generation, and once
   every daemon has taken one, its own tasks queue for good. The pool stays at
   its width, so the width check misses it.

garry prevents the second at its source and catches it if it happens anyway:

- `.pool_send()` runs each `everywhere()` under `suspendInterrupts()`, so a
  broadcast is sent whole. It cannot block: garry's pools set no memory limit
  for mirai's gate.
- garry cancels only a failed run's own read tasks, never a broadcast's.
- The progress check catches a generation left open by anything else, such as
  a user's own `everywhere()` on garry's profile.

Measured with mirai 2.7.2 and nanonext 1.10.2 (2026-11-03):

- Loss: in the strand window at 2, 3 and 4 daemons, sampled every 5 ms for
  2.5 s after the kill, all 1,418 stalled samples were at a pool below its
  width, which it fell to within 5 ms of the kill. Healthy pools of 2 to 4
  daemons under overlapping broadcasts and plain tasks showed no stalled sample
  in 12,111.
- Open generation: three readers, one busy, a broadcast whose final task
  queued for it, that task cancelled, then garry's broadcast. The progress check
  raised in about 2 s, with the pool at 3 of 3; with the width check alone the
  wait ran until a 20 s time limit ended it.

## Closing a pool

A pool closed while a daemon is mid-reply can hang the host for good: a race in
NNG's IPC transport, fixed in NNG 1.12.5 and not yet bundled in nanonext
(nanonext 1.10.2 bundles NNG 1.12.0, and 1.10.4 bundles 1.12.3). It hangs
dispatcher pools and width-1 direct profiles alike: on a fault-injection build
that widens the race, a direct profile closed with replies in flight hung in 3
of 3 runs, in `req0_pipe_stop()`.

`.pools_close()` is the only place garry closes a pool, for `garry_daemons()`.
Every daemon gets a pid probe, a `Sys.getpid()` broadcast it answers once it has
finished what it holds, and the close waits:

- on a dispatcher pool, until every probe has come back, or until its probes
  sit queued with nothing running: a stranded task or an open generation holds
  them for good, and no daemon of the pool is mid-task. `executing` alone is
  not enough, as a dispatcher reports 0 before it has assigned the probes;
- on a width-1 profile, which has no dispatcher, until its probe has replied
  or its daemon is gone.

At 3 s the wait names each pool still mid-task and the daemons that have not
answered the probe, by pid. A Ctrl-C, or 60 s, stops those daemons with
SIGKILL, since a dead daemon cannot be mid-reply; the close waits until each
pool has seen them go, then closes, says which daemons it stopped, and raises
the Ctrl-C again so `garry_daemons()` starts no pool. A pid counts only while
its process's command line names the pool's URL: a daemon lost before the
close never answers, and its pid may since belong to another process. A pool
still mid-task with no daemon garry can identify, such as one whose start was
interrupted before its pids were recorded, or any pool on Windows, where garry
reads no command line, fails the close with a `garry_pool_error` naming it.
`garry_daemons()` records the pids before any other task, so a daemon stuck
in the pool's setup can be stopped.

A close cancels nothing. Each run cancels its own queued reads, through the
handles it holds, before its clear: the scheduler's in-flight table, the
read-only loop's, and the composite routes' fetches (`.run_guard()` clears once
the run's own frames have exited). A width-1 profile has no dispatcher to drop
a task, so nothing is cancelled there.

A daemon that receives a task whose input region a clear has already freed
exits; a task already running keeps its input [M]. A compute task's inputs live
on the readers and on other compute daemons, so a failed run sends no clear
until every compute daemon has received what was queued for it: a no-op goes
to each used compute profile first, and a width-1 profile runs its queue in
order, so the no-op's reply means every task before it has run. The clears then
go to every used pool at once. The wait is each compute daemon's running task,
the tasks queued behind it and any kernel warm-up queued there: tens of seconds
behind a scan compile.

Measured with SIGINT mid-run [M]:
- A map plan lost a compute daemon in 14 of 20 runs with every clear sent at
  once.
- A plan whose compute tasks read other compute daemons' outputs (two 6-band
  sources, each a mean over band, stacked) lost one in 8 of 8 runs on main, and
  in 1 of 20 with the readers' clear merely sent after the compute profiles'.
- With the no-op first it lost none in 20 runs. A Ctrl-C returned a median
  1.19 s after the interrupt, at most 1.54 s.
- A deterministic case, a task queued on one compute daemon behind a 1.5 s task
  with its input on another, lost the daemon in 3 of 3 runs without the no-op
  and in 0 of 5 with it.

Nothing in a failure path or a close calls `unresolved()` on a run's task. A
reply that landed uncollected maps a region the run's clear frees, and
unserialising it then raises "mori: shared memory region not found";
`stop_mirai()` on such a handle returns `FALSE` without reading it [M, mirai
2.7.2].

A cancel drops a queued task; one already running resumes through the
interrupt and runs to its end (`.task_mirai()`), so a Ctrl-C or a failed run
returns once the tasks already running have ended. An interrupt
that lands inside cli's message code leaves the daemon's cli unable to format
any later message: 5 of 30 cancels did so with cli 3.6.6, and a pool that
survives a failed run's cancel would then report its next failures as cli's
own error. With the resume, 0 of 30 did.

## When nanonext fixes it

"a reader killed mid-broadcast strands the dispatcher, and the width check ends
the wait" in `tests/testthat/test-pool-liveness.R` asserts the strand itself
(a queued task, none running, a daemon short). A nanonext that fails the
stranded task, or hands it on, fails that assertion; garry's error stays the
same `garry_pool_error`.
