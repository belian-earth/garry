# JIT-compile a stage closure via anvl (executor bridge).

JIT-compile a stage closure via anvl (executor bridge).

## Usage

``` r
g_jit(f, device = NULL)
```

## Arguments

- f:

  Stage closure.

- device:

  Optional device override (e.g. "cuda"); NULL uses the anvl default
  device.

## Value

A compiled function (anvl `JitFunction`).
