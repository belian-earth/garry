# Key-only compute launches (P2): warmed kernels ship the jit cache
# key alone; a cold cache with no closure must signal the host to
# resend rather than fail opaquely. The happy path (fn = NULL against
# a warmed cache) is exercised by every distributed test.

test_that("a key-only compute task on a cold cache signals a jit miss", {
  expect_error(
    .daemon_run_compute_shm(paste0("k-cold-", Sys.getpid()), NULL,
                            list(), character(0), integer(0),
                            character(0), "rk-test"),
    "garry_jit_miss")
})

# A plan with kernels on the compute pool: a map over two files, which
# no read can fuse.
.kko_compute_plan <- function(k) {
  f <- fixture_gradient_f32()
  f2 <- file.path(tempdir(), "garry-kko-copy.tif")
  if (!file.exists(f2)) file.copy(f, f2)
  (lazy_source(f) + k) * lazy_source(f2)
}

test_that("a warm-up that fails reports it", {
  sp <- list(ck = paste0("k-bad-", Sys.getpid()), device = "cpu",
             fn = function(inp) stop("kernel does not compile"),
             dtypes = "f32", outers = 1L, nr = 2L, nc = 2L)
  expect_error(.daemon_warm_jit(list(sp)), "kernel does not compile")
  bad <- list(list(ck = "k-bad-pipe", dev = "cpu", F = NULL, op = "no_such_op",
                   nan_rm = TRUE, affine = NULL, masked = FALSE, n = 2L,
                   hs = 2L, nx = 2L))
  expect_error(.gd_warm_pipeline(bad))
})

test_that("a failed warm-up warns, is logged, and the run still finishes", {
  skip_if(!requireNamespace("garry", quietly = TRUE))
  local_pools(1, 1)
  log <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.task_log = log, garry.chunk_target_px = 400)
  x <- .kko_compute_plan(3)
  want <- collect(x, distributed = FALSE)
  invisible(collect(.kko_compute_plan(5), distributed = TRUE)) # the ABI check
  mirai::everywhere({
    ns <- asNamespace("garry")
    unlockBinding(".daemon_warm_jit", ns)
    assign(".daemon_warm_jit", function(specs) stop("mock warm failure"), envir = ns)
  }, .compute = garry:::.comp_profiles()[[1L]])
  expect_warning(got <- collect(x, distributed = TRUE), "mock warm failure")
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
  d <- read.csv(log)
  # keyed as its task: a kernel's cache key can hold a comma
  expect_match(d$key[d$event == "warm_fail"], "^warm[0-9]+_c1$")
})

test_that("a kernel resent to a daemon that lost it leaves a task-log row", {
  skip_if(!requireNamespace("garry", quietly = TRUE))
  local_pools(1, 1)
  log <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.task_log = log, garry.chunk_target_px = 400)
  x <- .kko_compute_plan(7)
  a <- collect(x, distributed = TRUE)
  mirai::everywhere({
    e <- asNamespace("garry")$.daemon_cache
    rm(list = ls(e, all.names = TRUE), envir = e)
  }, .compute = garry:::.comp_profiles()[[1L]])
  b <- collect(x, distributed = TRUE)
  expect_identical(b, a)
  expect_true("resend" %in% read.csv(log)$event)
})

test_that("a read's retries reach the task log", {
  withr::local_options(garry.read_retry = 2L)
  garry:::.daemon_retries_take() # any earlier test's
  n <- 0L
  got <- suppressWarnings(garry:::.gdal_with_retry(
    function() {
      n <<- n + 1L
      if (n < 3L) stop("blip")
      "ok"
    },
    "read",
    "x.tif"
  ))
  expect_identical(got, "ok")
  expect_identical(garry:::.daemon_retries_take(), 2L)
  expect_identical(garry:::.daemon_retries_take(), 0L)
  rows <- list()
  log_line <- function(event, key, ...) rows[[length(rows) + 1L]] <<- event
  garry:::.task_log_timed(log_line, "k", list(t0 = 1, t1 = 2, retries = 2L))
  expect_identical(unlist(rows), c("start", "end", "retry"))
})
