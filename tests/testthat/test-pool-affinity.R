# Reader CPU affinity (PR4 of design/placement-cost-pass.md). Gates:
# after garry_daemons(), each read daemon's Cpus_allowed_list is
# bounded to k CPUs and the sets are disjoint across readers; the cap
# is recorded for the placement pass; "off" leaves readers uncapped.
# Spike A (benchmarks/README.md 2026-07-29) established that this mask
# bounds the XLA client's thread pool and that k >= 2 is a hard floor.

skip_if_not_installed("mirai")
skip_if(Sys.info()[["sysname"]] != "Linux", "affinity is Linux-only")
skip_if(!nzchar(Sys.which("taskset")), "taskset not available")

.reader_cpu_lists <- function() {
  h <- mirai::everywhere({
    sub("Cpus_allowed_list:\\s*", "",
        grep("^Cpus_allowed_list:",
             readLines(sprintf("/proc/%d/status", Sys.getpid())),
             value = TRUE))
  }, .compute = "garry_read")
  vapply(h, function(m) m[], character(1))
}

.cpu_list_len <- function(s) {
  sum(vapply(strsplit(s, ",")[[1L]], function(part) {
    r <- as.integer(strsplit(part, "-")[[1L]])
    if (length(r) == 2L) r[[2L]] - r[[1L]] + 1L else 1L
  }, integer(1)))
}

test_that("read daemons get disjoint bounded CPU sets and the cap is recorded", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  cores <- parallel::detectCores()
  skip_if(cores < 5L, "cap is a no-op below 5 cores")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)

  k <- max(2L, cores %/% 2L)
  expect_identical(garry:::.garry_state$reader_threads, k)

  lists <- .reader_cpu_lists()
  expect_length(lists, 2L)
  expect_true(all(vapply(lists, .cpu_list_len, integer(1)) == k))
  expect_false(lists[[1L]] == lists[[2L]])
})

test_that("pool_affinity = 'off' leaves readers uncapped", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  old <- options(garry.pool_affinity = "off")
  on.exit(options(old), add = TRUE)
  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  expect_null(garry:::.garry_state$reader_threads)
  lists <- .reader_cpu_lists()
  cores <- parallel::detectCores()
  expect_true(all(vapply(lists, .cpu_list_len, integer(1)) == cores))
})

test_that("the compute pool is capped too and recorded for the cost model", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  cores <- parallel::detectCores()
  skip_if(cores < 5L, "cap is a no-op below 5 cores")
  garry_daemons(2, 2)
  on.exit(garry_daemons(0, 0), add = TRUE)
  k <- max(2L, cores %/% 2L)
  expect_identical(garry:::.garry_state$comp_threads, k)
  h <- mirai::everywhere({
    sub("Cpus_allowed_list:\\s*", "",
        grep("^Cpus_allowed_list:",
             readLines(sprintf("/proc/%d/status", Sys.getpid())),
             value = TRUE))
  }, .compute = "garry_compute")
  lists <- vapply(h, function(m) m[], character(1))
  expect_length(lists, 2L)
  expect_false(lists[[1L]] == lists[[2L]])
})
