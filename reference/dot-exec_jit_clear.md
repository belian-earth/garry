# Drop every kernel this process holds.

The cache is keyed on kernel content, so it is only ever a speed
optimisation; clearing it costs a recompile and nothing else.

## Usage

``` r
.exec_jit_clear()
```

## Value

`NULL`, invisibly.
