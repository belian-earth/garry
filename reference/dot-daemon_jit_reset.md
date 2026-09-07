# Daemon task body: start a run with a fresh jit cache on macOS.

Reusing a daemon's cached JitFunction across RUNS stalls on macOS: the
same family as the host-cache slowdown gated in `.exec_cached_jit`
(test-kernel-cache tripwire, run 33505350958) and the fused-on-reader
hang (test-compute-on-read). It surfaced on the daemons once kernel
signatures became stable across plans (`.fn_identity`, 2026-09-07): the
macOS check went from a 37 min pass to a 90 min elapsed kill inside
test-write-tif with 20 min of CPU, i.e. waiting, and Linux/Windows
timings were unchanged. Until debugged on real hardware every run starts
cold there; kernels are still shared across a run's tasks and key-only
launches still hit. A no-op elsewhere.

## Usage

``` r
.daemon_jit_reset()
```

## Value

`TRUE` if the cache was cleared, invisibly.

## Details

Internal (exported only so mirai daemons can address it via `::`).
