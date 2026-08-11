# List every garry option: default, current value, tier, description.

The registry surface for the flat `garry.*` option namespace: one row
per option with its tier (`user` day-one switches, `tuning`
budgets/targets, `calibration` cost-model constants), package default,
current session value and a one-line description. Values are validated
against the same registry when execution starts.

## Usage

``` r
garry_options()
```

## Value

A data.frame with columns `option`, `tier`, `default`, `current`, `set`
(is the session overriding the default?) and `description`.

## See also

[`garry_opt()`](https://belian-earth.github.io/garry/reference/garry_opt.md)
