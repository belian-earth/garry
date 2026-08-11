# Summarise a `garry.task_log` CSV.

Summarises the task log CSV the distributed scheduler writes when the
`garry.task_log` option is set (see
[`garry_options()`](https://belian-earth.github.io/garry/reference/garry_options.md);
schema `time,event,key,pool,slot,mb,store_mb,ready`): per-stage task
counts and run/queue-wait quantiles, maximum concurrency, the drain vs
host-tail split, and the peak measured (per-daemon anonymous RSS) vs
modelled (in-flight + resident) memory. It answers "where did the time
and memory go" for a distributed run.

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
