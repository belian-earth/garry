# The CPUs garry sizes and masks its pools from: this process's affinity
# list, counted no higher than a cgroup CPU quota, not detectCores()'s
# whole machine. test-pool-affinity.R checks real pools under a narrowed
# list.

.status <- function(dir, list) {
  f <- file.path(dir, "status")
  writeLines(
    c("Name:\tR", "Cpus_allowed:\tff", paste0("Cpus_allowed_list:\t", list)),
    f
  )
  f
}

test_that("the affinity list reads as CPU ids", {
  dir <- withr::local_tempdir()
  expect_identical(
    garry:::.cpus_allowed(.status(dir, "0-2,7,10-11")),
    c(0:2, 7L, 10:11)
  )
  expect_identical(garry:::.cpus_allowed(.status(dir, "16-19")), 16:19)
  expect_identical(garry:::.cpus_allowed(.status(dir, "5")), 5L)
  # no status file (not Linux) or no list in it: unknown, not an error
  expect_null(garry:::.cpus_allowed(file.path(dir, "absent")))
  writeLines("Name:\tR", file.path(dir, "status"))
  expect_null(garry:::.cpus_allowed(file.path(dir, "status")))
  # a list that is there and will not parse fails
  for (bad in c("0-x", "3-1", "", "1-2-3")) {
    expect_error(
      garry:::.cpus_allowed(.status(dir, bad)),
      class = "garry_cores_error"
    )
  }
})

test_that("a CPU quota is the tightest over the cgroup and its ancestors", {
  root <- withr::local_tempdir()
  self <- file.path(root, "self")
  lvl <- function(path, v) {
    d <- file.path(root, path)
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    writeLines(v, file.path(d, "cpu.max"))
  }
  writeLines("0::/job/step", self)
  lvl("job", "400000 100000")
  lvl("job/step", "max 100000")
  expect_identical(garry:::.garry_cgroup_cpus(root, self), 4)
  lvl("job/step", "150000 100000")
  expect_identical(garry:::.garry_cgroup_cpus(root, self), 1.5)
  # a container sees its own cgroup at the mount root
  writeLines("0::/", self)
  writeLines("250000 100000", file.path(root, "cpu.max"))
  expect_identical(garry:::.garry_cgroup_cpus(root, self), 2.5)
  # no quota anywhere, or no cgroup at all
  unlink(file.path(root, "cpu.max"))
  expect_identical(garry:::.garry_cgroup_cpus(root, self), Inf)
  expect_identical(
    garry:::.garry_cgroup_cpus(root, file.path(root, "absent")),
    Inf
  )
  # a quota file that is there and will not parse fails
  writeLines("0::/job/step", self)
  for (bad in c("lots 100000", "400000", "400000 0")) {
    lvl("job/step", bad)
    expect_error(
      garry:::.garry_cgroup_cpus(root, self),
      class = "garry_cores_error"
    )
  }
})

test_that("a CPU quota on cgroup v1 reads the cpu controller's CFS files", {
  root <- withr::local_tempdir()
  self <- file.path(root, "self")
  # a v1 container names its host path, which does not exist inside it
  writeLines(
    c(
      "5:cpuset:/docker/abc",
      "4:cpu,cpuacct:/docker/abc",
      "3:memory:/docker/abc"
    ),
    self
  )
  cpu <- file.path(root, "cpu")
  dir.create(cpu)
  writeLines("-1", file.path(cpu, "cpu.cfs_quota_us"))
  writeLines("100000", file.path(cpu, "cpu.cfs_period_us"))
  expect_identical(garry:::.garry_cgroup_cpus(root, self), Inf)
  writeLines("300000", file.path(cpu, "cpu.cfs_quota_us"))
  expect_identical(garry:::.garry_cgroup_cpus(root, self), 3)
})

test_that("the core count is the allowed CPUs, capped by a quota rounded up", {
  dir <- withr::local_tempdir()
  st <- .status(dir, "16-19")
  testthat::local_mocked_bindings(.garry_cgroup_cpus = function(...) Inf)
  expect_identical(garry:::.garry_cores(st), list(logical = 4L, cpus = 16:19))
  testthat::local_mocked_bindings(.garry_cgroup_cpus = function(...) 2.5)
  expect_identical(garry:::.garry_cores(st), list(logical = 3L, cpus = 16:19))
  testthat::local_mocked_bindings(.garry_cgroup_cpus = function(...) 0.5)
  expect_identical(garry:::.garry_cores(st)$logical, 1L)
})

test_that("pools sized with no arguments take one reader per allowed CPU", {
  withr::local_options(garry.device = "cpu")
  testthat::local_mocked_bindings(.garry_cores = function(...) {
    list(logical = 12L, cpus = 8:19)
  })
  got <- NULL
  # the first step after sizing: take the sizes and start no pool
  testthat::local_mocked_bindings(.garry_opt_check = function() {
    e <- parent.frame()
    got <<- c(read = e$read, compute = e$compute)
    stop("sized")
  })
  expect_error(garry_daemons(), "sized")
  expect_identical(got, c(read = 12L, compute = 4L))
})
