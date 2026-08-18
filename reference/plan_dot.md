# Render a Plan as DOT (Graphviz) text.

Render a Plan as DOT (Graphviz) text.

## Usage

``` r
plan_dot(plan)
```

## Arguments

- plan:

  A `Plan` from
  [`plan_lazy()`](https://belian-earth.github.io/garry/reference/plan_lazy.md),
  or anything
  [`plan_lazy()`](https://belian-earth.github.io/garry/reference/plan_lazy.md)
  accepts (a `LazyRaster`, a `LazyDataset`, or a named list of
  `LazyRaster`s), which is planned first.

## Value

A single DOT string.

## See also

[`plan_view()`](https://belian-earth.github.io/garry/reference/plan_view.md)
for the interactive DAG,
[`draw()`](https://belian-earth.github.io/garry/reference/draw.md) for
the user-facing pipeline visualisation.
