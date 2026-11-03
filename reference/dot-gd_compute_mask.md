# Daemon task body: compute one batch of the shared cleaned mask.

Replays the mask-cleaning morphology over a batch of QA slices and
writes one mask file per slice, which every band task reads, instead of
recomputing the morphology per band. Internal; daemons reach it through
`asNamespace("garry")`.

## Usage

``` r
.gd_compute_mask(job, k)
```

## Arguments

- job:

  `fmask_bins` and `out_bins`, one each per slice of the batch, and
  `free`, the fmask files to delete once the batch has read them.

- k:

  The batch's constants: `ny`, `nx`, `dev`, `ck`, and `kernel`, a
  program set, or `chain` and `halo` for a closure.
