# Summarise a `garry.task_log` CSV.

Summarises the task log CSV the distributed scheduler writes when the
`garry.task_log` option is set (see
[`garry_options()`](https://belian-earth.github.io/garry/reference/garry_options.md);
schema `time,event,key,pool,slot,mb,store_mb,ready`): per-stage task
counts and run/queue-wait quantiles, maximum concurrency, the drain vs
host-tail split, and the peak measured (per-daemon anonymous RSS) vs
modelled (in-flight + resident) memory, with the fleet peak split by
daemon role. Logs that carry them also report the calling process's peak
anonymous RSS, the binding memory cgroup's peak usage against its limit,
peak `/dev/shm` use, and the tightest compute admission budget. It
answers "where did the time and memory go" for a distributed run.

## Usage

``` r
garry_task_report(path)
```

## Arguments

- path:

  Path to a task-log CSV written by the scheduler.

## Value

Invisibly, a list: `events` (event counts), `tasks` (one row per
launch/done pair: key, pool, slot, mb, store_mb, wait_s, queue_s, run_s,
harvest_s), `stages` (per-stage counts, p50/p95 run and wait seconds,
p50 queue and harvest seconds), `pools` (per-pool task counts, summed
and p50 run seconds over every run, and the last run's daemon count and
utilisation, its busy seconds over daemons x the run's span),
`max_concurrency`, `drain_s`, `host_tail_s`, `peak_model_mb`,
`peak_rss_mb`, `peak_rss_by_role` (named MB), `peak_host_mb`,
`peak_cgroup_mb`, `cgroup_limit_mb`, `peak_shm_mb` and
`min_comp_budget_mb` (`NA` when the log has no such rows). Printed as a
cli summary.
