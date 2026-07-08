# Phase 11.1: split daemon pools (garry_daemons). Gates: pooled
# execution is IDENTICAL to single-threaded; read daemons never load
# anvl/PJRT; jit warm-up lands in the compute pool's cache; teardown
# and fallback to the default pool both work.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")

test_that("pooled distributed == single-threaded; pools stay lean", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)

  old <- options(garry.chunk_target_px = 400)   # force many chunks
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  pipelines <- list(
    map    = local({ a <- lazy_source(f); a * 2 + 1 }),
    stack  = local({
      a <- lazy_source(f); b <- lazy_source(f)
      reduce_over(lazy_stack(list(a + 1, b * 2)), "median", "t",
                  nan_rm = TRUE)
    }),
    reduce = local({
      a <- lazy_source(f)
      reduce_over(a * 2, "mean", c("x", "y"), nan_rm = TRUE)
    })
  )
  stores <- c("rds",
              if (requireNamespace("mori", quietly = TRUE)) "mori")
  for (nm in names(pipelines)) {
    p <- plan_lazy(pipelines[[nm]])
    single <- execute_plan(p)
    for (st in stores) {
      old_st <- options(garry.store = st)
      dist <- execute_plan_mirai(p)
      options(old_st)
      expect_equal(dist, single, tolerance = 1e-12,
                   label = paste("pooled", nm, st))
    }
  }

  # Read daemons executed reads without ever loading anvl/PJRT.
  anvl_on_read <- mirai::mirai("anvl" %in% loadedNamespaces(),
                               .compute = "garry_read")[]
  expect_false(anvl_on_read)

  # Warm-up populated the compute pool's jit cache (per-run keys, so
  # >= one entry per run that had compute stages).
  cache_n <- mirai::mirai(length(ls(garry:::.daemon_cache)),
                          .compute = "garry_compute")[]
  expect_gt(cache_n, 0L)
})

test_that("no pools set up falls back to the default profile", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  mirai::daemons(2)
  on.exit(mirai::daemons(0), add = TRUE)
  a <- lazy_source(fixture_gradient_f32())
  p <- plan_lazy(a + 1)
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-12)
})

test_that("no daemons at all raises the structured error", {
  expect_error(
    execute_plan_mirai(plan_lazy(lazy_source(fixture_gradient_f32()) + 1)),
    class = "garry_scheduler_error")
})
