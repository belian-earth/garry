# GPU pool smoke (D16): a mirai daemon compiles and runs garry's stage
# kernels on the CUDA device through the real route. A machine with no
# NVIDIA GPU or no CUDA plugin skips; a GPU that fails, fails.

skip_on_os(c("windows", "mac"))   # CUDA/PJRT-CUDA is Linux-only
# Gate on a visible NVIDIA GPU first, so PJRT_INSTALL=1 does not pull the
# large CUDA plugin just to fail on a GPU-less machine (e.g. CI).
skip_if(!nzchar(Sys.which("nvidia-smi")), "no NVIDIA GPU")
skip_if(!pjrt::plugins_downloaded("cuda"), "CUDA PJRT plugin not installed")

test_that("a full plan on garry.device='cuda' returns what plain R computes", {
  local_pools(2, 1)
  withr::local_options(garry.chunk_target_px = 400, garry.device = "cuda")
  f <- fixture_gradient_f32()
  a <- lazy_source(f); b <- lazy_source(f)
  expr <- reduce_over(lazy_stack(list(a + 1, b * 2)), "median", "t",
                      nan_rm = TRUE)
  p <- plan_lazy(expr)
  expect_true(all(vapply(p@stages, function(s)
    s@kind %in% c("source_read", "warp", "reduce_combine") ||
      s@device == "cuda", logical(1))))
  m <- .fixture_values(60, 40)
  expect_equal(unclass(execute_plan_mirai(p)), (m + 1 + m * 2) / 2,
               tolerance = 1e-6, ignore_attr = TRUE)
})
