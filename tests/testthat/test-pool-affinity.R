# Pool CPU affinity (PR4 of design/placement-cost-pass.md). Gates: after
# garry_daemons(), each daemon's Cpus_allowed_list is bounded to k CPUs
# and the sets are disjoint within a pool; the cap is recorded for the
# placement pass; "off" leaves readers uncapped. Spike A
# (design/benchmark-history.md 2026-07-29) established that this mask bounds
# the XLA client's thread pool and that k >= 2 is a hard floor.

skip_if(Sys.info()[["sysname"]] != "Linux", "affinity is Linux-only")
skip_if(!nzchar(Sys.which("taskset")), "taskset not available")

# Each daemon's CPU list, as the kernel reports it.
.cpu_lists <- function(profile) {
  unlist(.everywhere({
    sub("Cpus_allowed_list:\\s*", "",
        grep("^Cpus_allowed_list:",
             readLines(sprintf("/proc/%d/status", Sys.getpid())),
             value = TRUE))
  }, .compute = profile))
}

# "0-2,7" as c(0, 1, 2, 7).
.cpus <- function(s) {
  unlist(lapply(strsplit(s, ",")[[1L]], function(part) {
    r <- as.integer(strsplit(part, "-")[[1L]])
    seq(r[[1L]], r[[length(r)]])
  }))
}

test_that("each pool's daemons get disjoint bounded CPU sets and the cap is recorded", {
  # masks name real CPUs, so a mocked core count must not exceed them
  skip_if(garry:::.garry_cores()$logical < 6L, "needs 6 cores")
  testthat::local_mocked_bindings(.garry_cores = function() list(logical = 6L, physical = 6L))
  local_pools(2, 2)
  expect_identical(garry:::.garry_state$reader_threads, 3L)
  expect_identical(garry:::.garry_state$comp_threads, 3L)
  pools <- list(.cpu_lists("garry_read"), unlist(lapply(garry:::.comp_profiles(), .cpu_lists)))
  for (lists in pools) {
    expect_length(lists, 2L)
    sets <- lapply(lists, .cpus)
    expect_identical(lengths(sets, use.names = FALSE), c(3L, 3L))
    expect_length(intersect(sets[[1L]], sets[[2L]]), 0L)
  }
})

test_that("pool_affinity = 'off' leaves readers uncapped", {
  withr::local_options(garry.pool_affinity = "off")
  local_pools(1, 0)
  expect_null(garry:::.garry_state$reader_threads)
  # uncapped is whatever this process may use, which a container or a
  # confined test run sets below the machine's core count
  own <- grep("^Cpus_allowed_list:", readLines("/proc/self/status"), value = TRUE)
  expect_identical(unname(.cpu_lists("garry_read")), sub("Cpus_allowed_list:\\s*", "", own))
})

test_that("a uniform plan re-masks a pool a mixed scan plan left behind", {
  st <- garry:::.garry_state
  old <- mget(c("comp_threads", "comp_pids", "comp_mixed"), envir = st, ifnotfound = list(NULL))
  on.exit(for (n in names(old)) assign(n, old[[n]], envir = st), add = TRUE)
  calls <- 0L
  local_mocked_bindings(
    .pool_affinity_apply = function(pids, k = NULL) {
      calls <<- calls + 1L
      k
    },
    .garry_cores = function() list(logical = 8L, physical = 8L)
  )
  assign("comp_pids", 1:4, envir = st)
  assign("comp_threads", 2L, envir = st)
  garry:::.comp_pool_shape(4L, 1L) # mixed
  expect_true(st$comp_mixed)
  calls <- 0L
  garry:::.comp_pool_shape(4L) # uniform, same width as the narrow masks
  expect_identical(calls, 1L)
  expect_false(st$comp_mixed)
  garry:::.comp_pool_shape(4L) # now settled: no re-mask
  expect_identical(calls, 1L)
})

test_that("a mask that cannot be set says so", {
  # an empty PATH would lose the core count too: not what this test is about
  testthat::local_mocked_bindings(.garry_cores = function() list(logical = 8L, physical = 8L))
  bin <- withr::local_tempdir()
  fake <- file.path(bin, "taskset")
  writeLines(c("#!/bin/sh", "echo 'CPU not allowed' >&2", "exit 1"), fake)
  Sys.chmod(fake, "755")
  withr::local_envvar(PATH = bin)
  err <- expect_warning(
    v <- garry:::.pool_affinity_apply(Sys.getpid(), k = 2L),
    class = "garry_affinity_warning"
  )
  expect_null(v)
  expect_match(conditionMessage(err), "CPU not allowed", fixed = TRUE)
  unlink(fake)
  expect_warning(
    v <- garry:::.pool_affinity_apply(Sys.getpid(), k = 2L),
    "not installed",
    class = "garry_affinity_warning"
  )
  expect_null(v)
})
