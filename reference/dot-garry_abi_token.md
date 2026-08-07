# Daemon-facing ABI token: a hash of every `.daemon_*` entry point's formals plus the store layout version.

Daemons resolve `garry::.daemon_*` from their INSTALLED library while a
development host frequently runs a `load_all()` tree; a namespace skew
yields "unused argument" mirai errors at best and silent semantic drift
at worst (positional renames, new masking arguments).
[`packageVersion()`](https://rdrr.io/r/utils/packageDescription.html)
cannot guard this (constant through development); the formals can.
Internal (exported so daemons can evaluate their own token via `::`).

## Usage

``` r
.garry_abi_token()
```

## Value

A single hash string.
