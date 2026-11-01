# Risk gate (plan risk register): AnvlArray allocator behaviour under
# sustained chunk throughput, before Phase 7 multiplies it by N daemons.
# Asserts bounded growth of this process's anonymous memory, which holds
# PJRT's buffers as well as the R heap, across upload/run/download cycles.

skip_on_cran()
skip_on_os(c("windows", "mac")) # RssAnon is Linux-only

test_that("chunk cycles do not leak", {
  kernel <- g_jit(function(inputs) {
    a <- inputs[[1L]]
    list(out = (a * 2 + 1) / (a + 3))
  })
  m <- matrix(runif(256 * 256), 256, 256)
  cycle <- function() invisible(g_download(kernel(list(g_upload(m, "f32")))))
  # the second pass returns to the OS what the first one freed
  anon_mb <- function() {
    for (i in 1:2) {
      gc(full = TRUE)
      garry:::.garry_malloc_trim()
    }
    garry:::.garry_fleet_anon_mb(Sys.getpid())
  }

  # Warm up: compile + settle allocations.
  for (i in 1:120) cycle()
  base <- anon_mb()
  for (i in 1:100) cycle()

  # A leaked buffer per chunk is 26 MB (100 chunks x 256 KB) and a leaked R
  # copy twice that; clean cycles measure under 7 MB.
  expect_lt(anon_mb() - base, 13)
})
