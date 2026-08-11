# Execute a Plan across mirai daemons.

Requires garry's daemon pools: call
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
first (the function errors when the pools are not running). Results are
identical to
[`execute_plan()`](https://belian-earth.github.io/garry/reference/execute_plan.md)
(same plan, same kernels).

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

## See also

[`collect()`](https://belian-earth.github.io/garry/reference/collect.md),
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)
