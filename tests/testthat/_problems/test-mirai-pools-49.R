# Extracted from test-mirai-pools.R:49

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "garry", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
skip_if_not_installed("anvl")
skip_if_not_installed("mirai")

# test -------------------------------------------------------------------------
skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
garry_daemons(2, 1)
on.exit(garry_daemons(0, 0), add = TRUE)
old <- options(garry.chunk_target_px = 400)
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
anvl_on_read <- mirai::mirai("anvl" %in% loadedNamespaces(),
                               .compute = "garry_read")[]
expect_false(anvl_on_read)
