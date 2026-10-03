# Daemon-facing ABI token: a hash of every `.daemon_*` entry point's formals plus the store layout version.

Daemons resolve the `.daemon_*` bodies from their INSTALLED library
while a development host frequently runs a `load_all()` tree; a
namespace skew yields "unused argument" mirai errors at best and silent
semantic drift at worst (positional renames, new masking arguments).
[`packageVersion()`](https://rdrr.io/r/utils/packageDescription.html)
cannot guard this (constant through development); the formals can.
Internal; daemons evaluate their own token through
`asNamespace("garry")`.

## Usage

``` r
.garry_abi_token()
```

## Value

A single hash string.
