# Recognise a reduce-decomposable plan and lift its groups + upper IR, or NULL.

NULL when there is no upper IR (a pure composite -\> `.cd_spec`), when a
leaf reduce is not composite-reducible, or when the upper IR does not
close over the leaf reduces (a node consuming a raw source alongside a
reduce -\> the scheduler). `.gd_spec` gates fetchability and the
node-type whitelist.

## Usage

``` r
.gd_decompose(plan)
```
