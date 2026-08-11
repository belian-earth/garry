# Explain the scheduler's placement decisions for a computation.

Runs the placement pass over the plan the same way
`collect(distributed = TRUE)` would, and returns its decision table: one
row per fusable source -\> compute chain with the decision, the modelled
costs (cost mode), and the reason. Placement depends on runtime
resources, so pool widths are read from the live
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
pools when present; pass `read` / `compute` to ask "what would the pass
do with this topology" without daemons running.

## Usage

``` r
garry_explain_placement(
  x,
  read = NULL,
  compute = NULL,
  mode = garry_opt("placement")
)
```

## Arguments

- x:

  A `LazyRaster`, a named list of them (multi-export), or a `Plan`.

- read, compute:

  Pool widths to assume; default = the live pools (0 when none are
  running).

- mode:

  `"rules"` or `"cost"`; default `garry_opt("placement")`.

## Value

A data.frame with columns `source`, `compute`, `bands`, `flops_px`,
`move_mb`, `cost_fuse_s`, `cost_mat_s`, `decision`, `reason`.

## See also

[`garry_options()`](https://belian-earth.github.io/garry/reference/garry_options.md),
[`garry_task_report()`](https://belian-earth.github.io/garry/reference/garry_task_report.md)
