# Reverse-mode value-and-gradient of a scalar-loss closure (bridge).

Reverse-mode value-and-gradient of a scalar-loss closure (bridge).

## Usage

``` r
g_value_and_gradient(f, wrt)
```

## Arguments

- f:

  Function returning a scalar float; first argument is the
  differentiation target.

- wrt:

  Name of the argument to differentiate with respect to.

## Value

A function returning `list(value, grad$<wrt>)` (jit-compiled).
