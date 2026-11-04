# List every garry option: default, current value, tier, description.

The registry surface for the flat `garry.*` option namespace: one row
per option with its tier (`user` day-one switches, `tuning`
budgets/targets), package default, current session value and a one-line
description. Every `garry.*` option is checked against this registry
when a run starts and at
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md):
a name it does not hold (a typo or a retired option) or an invalid value
aborts with a `garry_option_error`.

## Usage

``` r
garry_options()
```

## Value

A data.frame with columns `option`, `tier`, `default`, `current`, `set`
(is the session overriding the default?) and `description`.

## See also

[`garry_opt()`](https://belian-earth.github.io/garry/reference/garry_opt.md)
