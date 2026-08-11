# Reverse-mode value-and-gradient of a scalar-loss closure (bridge).

User code should call
[`lazy_value_and_grad()`](https://belian-earth.github.io/garry/reference/lazy_value_and_grad.md)
instead.

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
