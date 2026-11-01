# Memory admission control. The configured budgets (ram_budget_mb x
# compute pool, read_budget_mb) are caps, not entitlements: execution
# fits them inside a fraction of what is ACTUALLY available, re-read
# during the drain. Availability must respect this process's cgroup, not
# just host MemAvailable -- inside a container / systemd scope / SLURM
# step the host figure is meaningless and budgeting on it overcommits
# straight into a cgroup OOM kill. test-read-budget.R starves these gates
# on a real run.

test_that("available RAM is the tighter of the host and the cgroup", {
  testthat::local_mocked_bindings(.garry_darwin_avail_mb = function(...) 2000)
  # a limit below the host's figure binds, and one above it does not
  testthat::local_mocked_bindings(.garry_cgroup_avail_mb = function(...) 100)
  expect_identical(.garry_ram_avail_mb(), 100)
  testthat::local_mocked_bindings(.garry_cgroup_avail_mb = function(...) 3000)
  expect_identical(.garry_ram_avail_mb(), 2000)
  # no limit leaves the host's figure
  testthat::local_mocked_bindings(.garry_cgroup_avail_mb = function(...) NA_real_)
  expect_identical(.garry_ram_avail_mb(), 2000)
})

test_that("Darwin reclaimable-memory parser reads vm_stat shapes", {
  lines <- c(
    "Mach Virtual Memory Statistics: (page size of 16384 bytes)",
    "Pages free:                               10000.",
    "Pages active:                            200000.",
    "Pages inactive:                          150000.",
    "Pages speculative:                        20000.",
    "Pages throttled:                              0.",
    "Pages wired down:                         90000.",
    "Pages purgeable:                          30000.")
  got <- garry:::.garry_darwin_avail_mb(lines)
  # (10000 + 150000 + 20000 + 30000) * 16384 / 2^20
  expect_equal(got, 210000 * 16384 / 2^20, tolerance = 1e-9)
  # malformed inputs degrade to NA, never error
  expect_true(is.na(garry:::.garry_darwin_avail_mb(character(0))))
  expect_true(is.na(garry:::.garry_darwin_avail_mb(c("nonsense", "lines"))))
  expect_true(is.na(garry:::.garry_darwin_avail_mb(
    c("Mach Virtual Memory Statistics: (page size of 16384 bytes)",
      "Pages wired down: 100."))))
})

test_that("cgroup headroom: tightest ancestor limit, page cache counted free", {
  root <- withr::local_tempdir()
  self <- file.path(root, "self")
  writeLines("0::/job/step/task", self)
  lvl <- function(path, mx, cur, inactive = NULL) {
    d <- file.path(root, path)
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    writeLines(mx, file.path(d, "memory.max"))
    writeLines(as.character(cur), file.path(d, "memory.current"))
    if (!is.null(inactive)) {
      writeLines(c("anon 1", paste("inactive_file", inactive)), file.path(d, "memory.stat"))
    }
  }
  mb <- 2^20
  lvl("job", as.character(10000 * mb), 9000 * mb, inactive = 3000 * mb) # 4000 MB
  lvl("job/step", "max", 1)
  lvl("job/step/task", "max", 1) # the leaf is unlimited
  expect_equal(.garry_cgroup_avail_mb(root, self), 4000)
  lvl("job/step", as.character(5000 * mb), 4000 * mb) # 1000 MB, tighter
  expect_equal(.garry_cgroup_avail_mb(root, self), 1000)
  writeLines("0::/free", self)
  dir.create(file.path(root, "free"))
  writeLines("max", file.path(root, "free", "memory.max"))
  writeLines("1", file.path(root, "free", "memory.current"))
  expect_true(is.na(.garry_cgroup_avail_mb(root, self)))
})

test_that("a cgroup file that will not read fails: it does not mean unlimited", {
  root <- withr::local_tempdir()
  self <- file.path(root, "self")
  writeLines("0::/job", self)
  d <- file.path(root, "job")
  dir.create(d)
  writeLines("not a number", file.path(d, "memory.max"))
  writeLines("1", file.path(d, "memory.current"))
  expect_error(.garry_cgroup_mem(root, self), class = "garry_memory_error")
  unlink(file.path(d, "memory.max"))
  dir.create(file.path(d, "memory.max")) # exists, cannot be read
  expect_error(.garry_cgroup_mem(root, self), class = "garry_memory_error")
  unlink(file.path(d, "memory.max"), recursive = TRUE)
  writeLines("1000", file.path(d, "memory.max"))
  writeLines("garbled", file.path(d, "memory.current"))
  expect_error(.garry_cgroup_mem(root, self), class = "garry_memory_error")
})

test_that("unknown RAM warns once: every budget is off", {
  rlang::reset_warning_verbosity("garry_ram_unknown")
  testthat::local_mocked_bindings(
    .garry_darwin_avail_mb = function(...) NA_real_,
    .garry_cgroup_avail_mb = function(...) NA_real_
  )
  testthat::local_mocked_bindings(
    Sys.meminfo = function(...) stop("meminfo is broken"),
    .package = "memuse"
  )
  expect_warning(v <- .garry_ram_avail_mb(), class = "garry_memory_warning")
  expect_true(is.na(v))
  expect_no_warning(.garry_ram_avail_mb())
  rlang::reset_warning_verbosity("garry_ram_unknown")
})

test_that("cgroup headroom: a namespaced container reads its limit at the root", {
  # Docker on cgroup v2 gives the container a private namespace: its own
  # cgroup is "0::/" and the limit files sit at the mount root.
  root <- withr::local_tempdir()
  self <- file.path(root, "self")
  writeLines("0::/", self)
  mb <- 2^20
  writeLines(as.character(240000 * mb), file.path(root, "memory.max"))
  writeLines(as.character(100000 * mb), file.path(root, "memory.current"))
  writeLines(c("anon 1", paste("inactive_file", 20000 * mb)), file.path(root, "memory.stat"))
  expect_equal(.garry_cgroup_avail_mb(root, self), 160000)
  cg <- garry:::.garry_cgroup_mem(root, self)
  expect_equal(cg$current, 100000)
  expect_equal(cg$limit, 240000)
  # a host's root cgroup has no limit files: still NA there
  unlink(file.path(root, c("memory.max", "memory.current")))
  expect_true(is.na(.garry_cgroup_avail_mb(root, self)))
})

test_that("cgroup headroom: v1 and hybrid hosts read the memory controller", {
  root <- withr::local_tempdir()
  self <- file.path(root, "self")
  mb <- 2^20
  mem <- file.path(root, "memory")
  lvl <- function(path, mx, cur) {
    d <- if (nzchar(path)) file.path(mem, path) else mem
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    writeLines(as.character(mx), file.path(d, "memory.limit_in_bytes"))
    writeLines(as.character(cur), file.path(d, "memory.usage_in_bytes"))
    writeLines(c("cache 1", "total_inactive_file 0"), file.path(d, "memory.stat"))
  }
  # hybrid: the unified line carries no memory controller, v1 does
  writeLines(c("12:memory:/batch/job", "1:name=systemd:/x", "0::/x"), self)
  lvl("", 9223372036854771712, 1) # v1 "unlimited" root
  lvl("batch", 9223372036854771712, 1)
  lvl("batch/job", 8000 * mb, 3000 * mb)
  expect_equal(.garry_cgroup_avail_mb(root, self), 5000)
  # a v1 container: its cgroup path does not exist inside it, its own
  # files sit at the controller's mount root
  unlink(file.path(mem, "batch"), recursive = TRUE)
  writeLines("9:cpuset,memory:/docker/abc", self)
  lvl("", 6000 * mb, 1000 * mb)
  expect_equal(.garry_cgroup_avail_mb(root, self), 5000)
})

test_that("a full store admits one kernel task per daemon, one assemble alone", {
  gate <- garry:::.store_gate_comp
  # under budget: anything runs
  expect_true(gate(100, 10, 200, 5L, 2L, kernel = TRUE))
  expect_true(gate(100, 10, 200, 5L, 2L, kernel = FALSE))
  # over budget: kernel tasks retire the regions, one per compute daemon
  expect_true(gate(300, 10, 200, 1L, 2L, kernel = TRUE))
  expect_false(gate(300, 10, 200, 2L, 2L, kernel = TRUE))
  # an assemble adds a region: only with nothing in flight
  expect_true(gate(300, 10, 200, 0L, 2L, kernel = FALSE))
  expect_false(gate(300, 10, 200, 1L, 2L, kernel = FALSE))
})

test_that("the /dev/shm probes read statvfs as df does", {
  skip_if(!dir.exists("/dev/shm"), "no /dev/shm")
  v <- garry:::.garry_statvfs_mb("/dev/shm")
  expect_named(v, c("total", "avail", "used"))
  expect_true(all(is.finite(v)) && v[["total"]] > 0)
  expect_lte(v[["used"]], v[["total"]])
  expect_true(is.na(garry:::.garry_statvfs_mb("/no/such/dir")[["total"]]))
  # other processes move the mount between any two reads of it
  testthat::local_mocked_bindings(
    .garry_statvfs_mb = function(path) c(total = 9, avail = 4, used = 5)
  )
  expect_identical(garry:::.garry_shm_free_mb(), 4)
  expect_identical(garry:::.garry_shm_used_mb(), 5)
})

test_that("the pipeline's compute cap follows exec_ram_fraction", {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1000)
  per_task <- garry:::.gd_strip_mb(4, 100, 100)
  withr::local_options(garry.exec_ram_fraction = 0.5)
  expect_identical(garry:::.gd_compute_cap(4, 100, 100, 1e4L), as.integer(floor(500 / per_task)))
})
