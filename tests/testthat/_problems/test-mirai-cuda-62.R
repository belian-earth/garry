# Extracted from test-mirai-cuda.R:62

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "garry", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
.cuda_available <- function() {
  ok <- tryCatch({
    r <- g_download(g_jit(function(inputs) list(o = inputs[[1L]] * 2),
                          device = "cuda")(
      list(g_upload(matrix(1, 2, 2), "f32", device = "cuda"))))
    isTRUE(all(r$o == 2))
  }, error = function(e) FALSE)
  ok
}

# test -------------------------------------------------------------------------
skip_if(!.cuda_available(), "CUDA PJRT plugin unavailable")
skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
garry_daemons(2, 1)
on.exit(garry_daemons(0, 0), add = TRUE)
old <- options(garry.chunk_target_px = 400)
on.exit(options(old), add = TRUE)
f <- fixture_gradient_f32()
a <- lazy_source(f)
b <- lazy_source(f)
expr <- reduce_over(lazy_stack(list(a + 1, b * 2)), "median", "t",
                      nan_rm = TRUE)
cpu <- collect(expr)
old_dev <- options(garry.device = "cuda")
on.exit(options(old_dev), add = TRUE)
p <- plan_lazy(expr)
expect_true(all(vapply(p@stages, function(s)
    s@kind %in% c("source_read", "warp", "reduce_combine") ||
      s@device == "cuda", logical(1))))
for (st in c("rds", if (requireNamespace("mori", quietly = TRUE)) "mori")) {
    old_st <- options(garry.store = st)
    gpu <- execute_plan_mirai(p)
    options(old_st)
    expect_equal(gpu, cpu, tolerance = 1e-6, label = paste("cuda", st))
  }
