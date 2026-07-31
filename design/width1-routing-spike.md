# Width-1 mirai profile routing spike

Date: 2026-07-31. Roadmap item 10 of the deep-review synthesis
(`design/deep-review-2026-07-31/SYNTHESIS.md`); execution-review axis 1
("the BEHIND: daemon identity"). Script:
`benchmarks/width1-routing-spike.R` (20-core box, mirai current).

## Question

mirai pools are anonymous task queues: the scheduler cannot route a
task to a chosen daemon. garry has paid for that three times (warm-up
must broadcast to every daemon; wide pools multiply scan compiles,
measured OOM at compute=10; drain-time warm-up rejected in phase 9b),
and the cold-kernel slow start plus the `scan_compile_mb` surcharge
exist as probabilistic workarounds. Would one width-1 profile per
daemon give exact daemon identity at negligible dispatch cost?

## Results

| Experiment | Result |
|---|---|
| Dispatch overhead, 2000 trivial tasks | width-8 pool 43.5 us/task; 8 x width-1 round-robin 56.0 us/task (+12.5 us, 1.29x) |
| Identity | 200/200 tasks landed on the addressed daemon; 8 distinct pids across 8 profiles |
| Warm-state routing (0.5 s fake compile in `garry:::.daemon_cache`, 16 tasks of 0.05 s) | directed at 2 pre-warmed daemons: 0.41 s; anonymous width-8 pool: 1.68 s (every daemon compiled cold) |

Two spike traps worth recording:

1. mirai daemons RESET the global environment between tasks, so
   daemon-side warmth must live in a namespace environment — which is
   exactly where garry already keeps it (`.daemon_cache`). The toy
   warm state therefore uses `garry:::.daemon_cache` and mirrors the
   real jit cache faithfully.
2. `garry:::.daemon_cache[["k"]] <- v` parses as an assignment back
   through `:::` and fails; grab the environment reference first.

## Verdict: GO (option retained, follow-up sized)

- Overhead is negligible where it matters: +12.5 us/task against
  garry's >=0.3 s task grain is ~0.004%. The 1.29x ratio only shows on
  sub-millisecond toy tasks.
- Identity is exact, with no mirai changes needed.
- The routing win is real: directed dispatch onto pre-warmed daemons
  is bounded by work, not by (daemons x compile).

Follow-up shape (NOT built in this pass): a scheduler dispatch mode
where the compute pool is created as N width-1 profiles
(`garry_comp_1..N`), the drain tracks per-daemon warmth (`warmed_ck`
becomes per-profile), and tasks of a cold-expensive kernel route only
to profiles that have completed one. That retires the slow-start ramp
and the `scan_compile_mb` surcharge for routed kernels and reopens
wide pools for scan tails. Two costs to size then:

1. One dispatcher process per profile (default mirai topology); check
   `dispatcher = FALSE` direct connections for width-1 profiles first,
   which would make the fleet LIGHTER than today's dispatched pool.
2. Load balance within the routed subset is the scheduler's job again
   (round-robin over ready profiles suffices at garry's task grain).

The fallback machinery (slow start, surcharge) stays as-is until the
follow-up lands; nothing in the current scheduler changes with this
spike.
