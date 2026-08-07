# Daemon task body: pre-compile stage closures for their modal chunk shape.

Runs on compute-pool daemons at run start (see
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)),
while the read pool owns the network drain: fills the per-daemon jit
cache and triggers one dummy execution per stage so the XLA compile
(~0.9 s/stage measured) never lands on a tail chunk. Get-or-create
against the same cache keys the real tasks use; failures are swallowed
(warm-up is an optimisation, never a correctness dependency).

## Usage

``` r
.daemon_warm_jit(specs)
```

## Arguments

- specs:

  List of per-stage specs: `ck` cache key, `fn` stage closure, `dtypes`
  per-input upload dtypes, `nr`/`nc` modal input dims.

## Value

`NULL`, invisibly.

## Details

Internal (exported only so mirai daemons can address it via `::`).
