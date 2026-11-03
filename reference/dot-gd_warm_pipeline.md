# Daemon task body: pre-compile the pipeline lean kernels.

Runs on each compute-pool daemon while the read pool owns the fetch
drain, so the XLA compile never lands on the post-fetch tail. A program
compiles every strip height and runs nothing. A closure compiles only by
running, once per strip height on `g_fill` dummies, each as much memory
as a real strip. A failure raises: the host reports it, and a band task
compiles the kernel.

## Usage

``` r
.gd_warm_pipeline(specs)
```

## Arguments

- specs:

  List of kernel specs: `ck`, `set` the program set, or `F` and `reduce`
  for a closure, `op`, `nan_rm`, `affine`, `masked`, `dev`, `n` slice
  count, `hs` strip heights, `nx`.

## Value

`NULL`, invisibly.

## Details

Internal; daemons reach it through `asNamespace("garry")`.
