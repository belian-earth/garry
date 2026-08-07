# Execute a Plan across mirai daemons.

Requires
[`mirai::daemons()`](https://mirai.r-lib.org/reference/daemons.html) to
be set by the caller. Results are identical to
[`execute_plan()`](https://belian-earth.github.io/garry/reference/execute_plan.md)
(same plan, same kernels; the equivalence is gate-tested).

## Usage

``` r
execute_plan_mirai(
  plan,
  path = NULL,
  nodata = NULL,
  band_names = NULL,
  wspec = NULL
)
```

## Arguments

- plan:

  A `Plan`.

- path, nodata, band_names, wspec:

  As in
  [`execute_plan()`](https://belian-earth.github.io/garry/reference/execute_plan.md).

## Value

As
[`execute_plan()`](https://belian-earth.github.io/garry/reference/execute_plan.md).
