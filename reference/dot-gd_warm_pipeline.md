# Daemon task body: pre-compile the pipeline lean kernels.

Runs on each compute-pool daemon while the read pool owns the fetch
drain: get-or-create each spec's JitFunction under the same `ck` the
real band tasks use, then execute once per strip height on `g_fill`
dummies (the fill is represented in the program — no host bytes move) so
the XLA compile never lands on the post-fetch tail. Failures fall back
to the plain client wake; warm-up is an optimisation, never a
correctness dependency.

## Usage

``` r
.gd_warm_pipeline(specs)
```

## Arguments

- specs:

  List of kernel specs: `ck`, `F`, `op`, `nan_rm`, `affine`, `masked`,
  `dev`, `n` slice count, `hs` strip heights, `nx`.

## Value

`NULL`, invisibly.

## Details

Internal (exported only so mirai daemons can address it via `::`).
