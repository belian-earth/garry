# Daemon task body: pre-compile stage closures for their modal chunk shape.

Runs on compute-pool daemons at run start (see
[`garry_daemons()`](https://belian-earth.github.io/garry/reference/garry_daemons.md)),
while the read pool owns the network drain: fills the per-daemon jit
cache, compiling a program's first shape or tracing a closure through
one dummy execution, so the XLA compile never lands on a tail chunk.
Get-or-create against the same cache keys the real tasks use. A failure
raises: the host clears the kernel's warm mark, reports it, and the
kernel's first task compiles it.

## Usage

``` r
.daemon_warm_jit(specs)
```

## Arguments

- specs:

  List of per-stage specs: `ck` cache key, `fn` stage closure, `dtypes`
  per-input upload dtypes, `nr`/`nc` modal input dims, `ring` whether
  the kernel takes `.ring_cells()`.

## Value

`NULL`, invisibly.

## Details

Internal; daemons reach it through `asNamespace("garry")`.
