# GPU pool smoke (D16): a mirai daemon compiles and runs a garry stage
# kernel on the CUDA device and returns correct values. Skips wherever
# CUDA/PJRT-CUDA is unavailable.

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
