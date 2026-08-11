# Plan a LazyRaster: run all planner passes and export a Plan.

Runs the full planner pass pipeline and returns a `Plan`: the pipeline's
operations fused into schedulable stages over a chunk grid, ready for an
executor.
[`collect()`](https://belian-earth.github.io/garry/reference/collect.md)
calls this internally, so most code never needs it directly; it is
useful for inspecting a pipeline with
[`plan_dot()`](https://belian-earth.github.io/garry/reference/plan_dot.md)
or executing a plan by hand.

## Usage

``` r
plan_lazy(x)
```

## Arguments

- x:

  A `LazyRaster`, or a named list of them (multi-export: one graph, one
  execution, several sinks).

## Value

A `Plan`.

## See also

[`execute_plan()`](https://belian-earth.github.io/garry/reference/execute_plan.md),
[`plan_dot()`](https://belian-earth.github.io/garry/reference/plan_dot.md)
