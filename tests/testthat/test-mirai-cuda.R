# GPU pool smoke (D16): a mirai daemon compiles and runs a garry stage
# kernel on the CUDA device and returns correct values. Skips wherever
# CUDA/PJRT-CUDA is unavailable.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
skip_on_os(c("windows", "mac"))   # CUDA/PJRT-CUDA is Linux-only

.cuda_available <- function() {
  # Gate on a visible NVIDIA GPU first, so PJRT_INSTALL=1 does not pull the large
  # CUDA plugin just to fail on a GPU-less machine (e.g. CI).
  if (!nzchar(Sys.which("nvidia-smi"))) return(FALSE)
  ok <- tryCatch({
    r <- g_download(g_jit(function(inputs) list(o = inputs[[1L]] * 2),
                          device = "cuda")(
      list(g_upload(matrix(1, 2, 2), "f32", device = "cuda"))))
    isTRUE(all(r$o == 2))
  }, error = function(e) FALSE)
  ok
}

test_that("a daemon runs a garry kernel on CUDA", {
  skip_if(!.cuda_available(), "CUDA PJRT plugin unavailable")
  mirai::daemons(1)
  on.exit(mirai::daemons(0), add = TRUE)

  m <- matrix(runif(64 * 64), 64, 64)
  task <- mirai::mirai({
    jf <- garry::g_jit(function(inputs) {
      a <- inputs[[1L]]
      list(out = (a * 2 + 1) / (a + 3))
    }, device = "cuda")
    garry::g_download(jf(list(garry::g_upload(m, "f32", device = "cuda"))))$out
  }, m = m)
  res <- task[]
  expect_false(inherits(res, c("miraiError", "errorValue")))
  expect_equal(res, (m * 2 + 1) / (m + 3), tolerance = 1e-6)
})

test_that("a full plan on garry.device='cuda' matches the CPU result
           (pooled, both stores)", {
  skip_if(!.cuda_available(), "CUDA PJRT plugin unavailable")
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  a <- lazy_source(f); b <- lazy_source(f)
  expr <- reduce_over(lazy_stack(list(a + 1, b * 2)), "median", "t",
                      nan_rm = TRUE)

  cpu <- collect(expr)   # single-threaded, default device

  old_dev <- options(garry.device = "cuda")
  on.exit(options(old_dev), add = TRUE)
  p <- plan_lazy(expr)
  expect_true(all(vapply(p@stages, function(s)
    s@kind %in% c("source_read", "warp", "reduce_combine") ||
      s@device == "cuda", logical(1))))
  for (st in "mori") {
    old_st <- options(garry.store = st)
    gpu <- execute_plan_mirai(p)
    options(old_st)
    expect_equal(gpu, cpu, tolerance = 1e-6, label = paste("cuda", st),
                 ignore_attr = "gis")
  }
})
