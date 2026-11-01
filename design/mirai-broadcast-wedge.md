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

A run's region drops are fire-and-forget broadcasts on the read pool. A reader
killed for memory at that moment left the pool alive by every check garry had,
so each later wait spun forever: the two survivors kept `.assert_pools_alive()`
satisfied.

`.assert_pools_moving()` in `R/pools.R` ends the wait. A queue with nothing
running and nothing finished across two checks a second apart is this state,
because a task waits on an idle daemon for milliseconds at most. It resets the
profile and raises a `garry_pool_error`, and `garry_daemons()` restores the pool.

## When mirai fixes it

Two tests in `tests/testthat/test-pool-liveness.R` rest on today's behaviour and
will fail together: "a reader lost with a broadcast task queued for it ends the
wait" and "a broadcast nobody waits for cannot strand the next wait". That
failure is the signal that the reset can go.
