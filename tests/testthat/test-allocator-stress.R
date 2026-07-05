# Risk gate (plan risk register): AnvlArray allocator behaviour under
# sustained chunk throughput, before Phase 7 multiplies it by N daemons.
# Asserts bounded growth of R-visible memory across hundreds of
# upload/run/download cycles.

skip_if_not_installed("anvl")
skip_on_cran()

test_that("500 chunk cycles do not leak R-visible memory", {
  skip_if(nzchar(Sys.getenv("GARRY_SKIP_STRESS")), "stress test skipped")

  kernel <- g_jit(function(inputs) {
    a <- inputs[[1L]]
    list(out = (a * 2 + 1) / (a + 3))
  })
  m <- matrix(runif(256 * 256), 256, 256)

  # Warm up: compile + settle allocations.
  for (i in 1:20) invisible(g_download(kernel(list(g_upload(m, "f32")))))
  gc(full = TRUE)
  base <- sum(gc()[, 2L])   # "(Mb)" used column

  for (i in 1:500) {
    invisible(g_download(kernel(list(g_upload(m, "f32")))))
    if (i %% 100 == 0) gc(full = TRUE)
  }
  gc(full = TRUE)
  after <- sum(gc()[, 2L])

  # Allow modest jitter; catch monotonic per-chunk leaks (500 chunks x
  # 256 KB would be ~130 MB if buffers leaked).
  expect_lt(after - base, 20)
})
