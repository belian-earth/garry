# TODO: anvl as the only compute backend (parked)

Hugh's long-run preference (2026-07-14): drop the dual-backend design and make
anvl the single compute backend, removing the base-R "oracle" fallbacks in the
`g_*` vocabulary (`R/ops.R`). Not urgent; CRAN is explicitly not a near-term
goal, so the anvl-free / on-CRAN advantage of the fallbacks does not apply.

## What the base fallbacks currently buy (what we'd lose)

Each `g_*` op has two branches: `if (.g_traced(x)) anvl::nv_*(x)` else a plain-R
implementation. The base branch is the pure-R **oracle**, which today serves:

1. **The correctness reference.** Core gates are `distributed == oracle` and
   `anvl == oracle`: the compiled XLA kernels are validated against the plain-R
   result. Removing the oracle removes that check.
2. **anvl-free testing/dev.** anvl is a heavy non-CRAN Suggests (PJRT plugins);
   most tests only `skip_if_not_installed("anvl")` for the traced path while the
   oracle path runs everywhere.
3. **A readable spec** of each op (`is.na`, `trunc`, `ifelse`).

## If/when we consolidate

- Replace (1) with a different correctness reference: golden fixtures captured
  from a trusted anvl build, or cross-checks against terra/gdalraster on small
  cases. Decide before deleting the oracle.
- (2) becomes: anvl required to run any real test; keep a thin set of pure-R
  planner/dim tests that don't touch compute.
- The `g_*` layer still has value even with one backend: it carries garry
  semantics (nodata = NaN, dtype strings, the last-two-dims focal convention,
  scalar promotion) and decouples user closures from anvl's exact API. Keep the
  `g_*` seam; just collapse each op to its traced branch.

Revisit when the anvl API stabilises and a replacement correctness reference is
chosen.
