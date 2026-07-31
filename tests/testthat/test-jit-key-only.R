# Key-only compute launches (P2): warmed kernels ship the jit cache
# key alone; a cold cache with no closure must signal the host to
# resend rather than fail opaquely. The happy path (fn = NULL against
# a warmed cache) is exercised by every distributed test that runs
# with jit_warmup = TRUE.

test_that("a key-only compute task on a cold cache signals a jit miss", {
  expect_error(
    .daemon_run_compute_shm(paste0("k-cold-", Sys.getpid()), NULL,
                            list(), character(0), integer(0),
                            character(0), "rk-test"),
    "garry_jit_miss")
})
