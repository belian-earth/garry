# Drop every cached executable held by the single-process executor.

The cache is keyed on stage structure, so it is only ever a speed
optimisation; clearing it costs a recompile and nothing else.

## Usage

``` r
.exec_jit_clear()
```

## Value

`NULL`, invisibly.
