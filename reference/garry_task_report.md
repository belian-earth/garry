# Summarise a `garry.task_log` CSV.

Converts the distributed scheduler's task log (option `garry.task_log`;
schema `time,event,key,pool,slot,mb,store_mb,ready`) from a developer
trace into an operator report: per-stage task counts and run/queue-wait
quantiles, maximum concurrency, the drain vs host-tail split, and the
peak measured (per-daemon anon RSS) vs modelled (in-flight + resident)
memory. Every diagnosis in the design history parsed this CSV ad hoc;
this locks the schema and answers the standing "where did the time and
memory go".

## Usage

``` r
garry_task_report(path)
```

## Arguments

- path:

  Path to a task-log CSV written by the scheduler.

## Value

Invisibly, a list: `events` (event counts), `tasks` (one row per
launch/done pair: key, pool, slot, mb, store_mb, wait_s, run_s),
`stages` (per-stage counts and p50/p95 run and wait seconds),
`max_concurrency`, `drain_s`, `host_tail_s`, `peak_model_mb`,
`peak_rss_mb`. Printed as a cli summary.
