# Phase 10b: the memory session

Gap item 1 of design/phase10-odc-gaps.md: garry's benchmark fleet
peaks at 10.4 GB (cgroup v2 memory.peak) where ODC+dask does the same
work in 4.3 GB. The difference is structural — 12 R+XLA daemon
processes against one process with 20 threads — but "structural"
is not a number. This session measures where the 10.4 GB sits and
takes the levers that survive measurement, at wall parity.

## Hypotheses

- **H1 GDAL caches.** GDAL_CACHEMAX is capped at 256 MB in the
  benchmark env, but that is PER PROCESS: 12 daemons x 256 MB = 3 GB
  of block cache alone if reads fill it. Reads are one-shot
  whole-window (nothing re-reads a block), so the block cache buys
  nothing; odc sets VSI_CACHE=False for bulk reads on the same
  reasoning. Expect: GDAL_CACHEMAX=64 or lower and VSI_CACHE=FALSE
  on daemons cuts gigabytes with zero wall change.
- **H2 Per-daemon process base.** R session + PJRT CPU runtime +
  garry/anvl namespaces: expect 150-250 MB per daemon before any
  work, x12 = 2-3 GB floor that only daemon count moves.
- **H3 Transient compute buffers.** During a fused chunk: ~110 store
  extractions live as R doubles (~2 MB each), upload conversion
  copies, XLA temp buffers for the 55-layer sort-based median. The
  ram_budget estimate (~1.5 KB/px) says ~350 MB per in-flight
  compute chunk. Peak should coincide with many daemons computing
  simultaneously (band tails), not with the drain.
- **H4 Shared memory accounting.** mori regions are mapped by
  producer, consumers, and host; cgroup counts them once but
  per-PID RSS multi-counts. PSS (smaps_rollup) apportions correctly;
  eager release already bounds pinned shm to ~1.5 GB. Expect shm to
  be visible but not the lever.
- **H5 Daemon count.** The drain is link-bandwidth-bound and 12 vs
  16 daemons was wall-identical in 9b; if 8 daemons still saturate
  the link, that is a ~33% cut in H1+H2 terms for free. (24-daemon
  probe already showed queuing, not throughput.)

## Method

1. Baseline: benchmark run in a dedicated systemd scope; sampler
   reads the scope's cgroup.procs every ~200 ms and records per-PID
   /proc/<pid>/smaps_rollup (Pss, Pss_Anon, Pss_File, Pss_Shmem,
   Rss) plus cgroup memory.current, aligned with garry.task_log
   events (launch/done/drain_end/host_end). Answers: when is the
   peak, which PIDs hold it, in what category.
2. Attribution: everywhere() probes on daemons after the drain —
   gdalraster cache used, R gc() heap, anvl jit cache footprint,
   pinned shm regions — reconciled against the PSS categories.
3. Levers, one at a time, interleaved runs (WiFi drift means only
   within-sitting ratios count): GDAL_CACHEMAX 256 -> 64 -> 32,
   VSI_CACHE=FALSE, daemons 12 -> 8. Gate: fleet cgroup peak drops
   materially at wall parity (within the sitting's drift band).
4. Adopt: winning settings become scheduler daemon defaults (set via
   everywhere() unless the user already set them) or benchmark-env
   documentation, whichever the measurement justifies.

## Results (2026-07-08, one sitting, interleaved)

All runs: 3 bands, mori store, cgroup v2 peak. Wall drift band for
12-daemon runs this sitting was ~37-39 s.

| config | peak | wall |
|---|---|---|
| baseline (x2) | 9.32 / 9.83 GB | 41.2* / 38.6 s |
| malloc thresholds + compute-task gc | 7.03 GB | 36.8 s |
| same + GDAL_CACHEMAX=64 + VSI_CACHE=FALSE | 7.46 GB | 37.7 s |
| all levers, 8 daemons | 6.68 GB | 44.9 s |

*first run of the sitting; includes warm-page effects.

Where the baseline 9.3-9.8 GB sat (per-PID PSS at peak, which lands
in the band tails ~t=38 of ~41 s): daemon base ~108 MB anon each
after init (1.3 GB floor); a drain plateau of ~200-250 MB/daemon;
compute daemons spiked to 1.2-1.7 GB anon EACH and stayed there.

- **H1 GDAL caches: REFUTED.** gdal_cache_used() reads 0 on every
  daemon post-run even at CACHEMAX=256 — whole-window reads stream
  through without filling the block cache — and VSI_CACHE was
  already FALSE (GDAL's default; the benchmark never set it).
  Trimming CACHEMAX and setting VSI_CACHE=FALSE changed nothing
  (7.46 vs 7.03 GB is sitting noise).
- **H2 base: confirmed but small.** ~108 MB/daemon, 1.3 GB floor.
- **H3 compute transients: confirmed, and the mechanism is malloc
  retention, not live objects.** Offline single-process repro: one
  fused chunk (110 uploads + 55-layer nan_rm median) leaves the
  process at ~650 MB anon; a final gc() returns almost nothing
  (glibc arenas retain the freed pages); consecutive chunks stack
  toward ~800 MB+. With MALLOC_MMAP_THRESHOLD_=131072 and
  MALLOC_TRIM_THRESHOLD_=131072 plus gc(FALSE) between chunks the
  plateau is ~305 MB, flat across chunks, at ~0.1 s/chunk cost
  (1.62 -> 1.74 s). MALLOC_ARENA_MAX=2 adds nothing on top (the
  mmap threshold already routes large buffers around arenas).
- **H4 shm: confirmed non-lever.** ~1.0-1.3 GB PSS_Shmem at peak,
  bounded by eager release.
- **H5 fewer daemons: REFUTED on wall.** 8 daemons drop the peak to
  6.68 GB but the drain stretches (drain_end 47.6 s vs ~40 s): the
  link needed 12 streams this sitting. Memory does not buy a wall
  regression; 12 stays.

Adopted: gc(FALSE) + rm of chunk locals at the end of both compute
task bodies in scheduler.R (18 gc calls per benchmark run, ~50 ms
each, mostly overlapped by the drain), and the two MALLOC_*
thresholds in the benchmark env ahead of daemons() — they must be
present at daemon exec, so garry cannot set them from everywhere().
Net: fleet peak 9.3-9.8 -> 7.0 GB (-25-28%) at wall parity
(36.8 s was the sitting's best wall).

The remaining ~2.7 GB gap to ODC's 4.3 GB is the process model:
12 R+PJRT bases (1.3 GB), per-process in-chunk working sets
(~0.3-1 GB per active compute daemon; ram_budget-governed), and the
drain plateau — none of which shrink without sharing a process.
That is the v2 threads/pool question, out of scope here.

## Non-goals

Re-architecting the process model (threads, forked workers, one
process per core with shared PJRT) is out of scope: it is the v2
question. GPU residency is a separate session. The chunk tiling is
not revisited (finer chunks measured slower in phase 10, item 3).
