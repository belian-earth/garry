# Memory admission control. The configured budgets (ram_budget_mb x
# compute pool, read_budget_mb) are caps, not entitlements: execution
# fits them inside a fraction of what is ACTUALLY available, re-read
# during the drain. Availability must respect this process's cgroup, not
# just host MemAvailable -- inside a container / systemd scope / SLURM
# step the host figure is meaningless and budgeting on it overcommits
# straight into a cgroup OOM kill.

test_that("available RAM accounts for a cgroup limit when one applies", {
  skip_on_os(c("windows", "mac", "solaris"))
  skip_if_not(file.exists("/proc/meminfo"))
  host <- .garry_ram_avail_mb()
  expect_true(is.na(host) || host > 0)

  cg <- .garry_cgroup_avail_mb()
  if (is.na(cg)) {
    # No (or unlimited) cgroup: availability is just the host figure.
    succeed()
  } else {
    # Under a limit, the reported figure can never exceed the headroom.
    # The two reads are not atomic (cgroup usage moves between them), so
    # allow real drift — the invariant under test is "cgroup-bounded",
    # not "instantaneously equal".
    expect_lte(host, cg + 128)
  }
})

test_that("cgroup headroom is NA when unlimited or unreadable", {
  skip_on_os(c("windows", "mac", "solaris"))
  # Whatever this process sits in, the helper must return a number or NA
  # and never error -- it runs on every distributed execution.
  v <- .garry_cgroup_avail_mb()
  expect_true(is.na(v) || (is.numeric(v) && v >= 0))
})

test_that("the exec_ram_fraction option is registered and sane", {
  f <- garry_opt("exec_ram_fraction")
  expect_true(is.numeric(f), f > 0, f <= 1)
})

test_that("a distributed run still completes with a tiny memory fraction", {
  skip_on_cran()
  # Squeezing the fraction to ~0 drives every gate to its floor (one
  # compute task, one read window at a time). That must serialise, not
  # deadlock, and must not change the answer.
  f <- fixture_gradient_f32()
  g <- graph_new()
  out <- reduce_over(lazy_stack(lapply(1:4, function(i)
    lazy_source(f, graph = g) * i), along = "t"), "sum", "t", nan_rm = TRUE)
  mem <- collect(out, distributed = FALSE)

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.exec_ram_fraction = 1e-6,
                 garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)
  # The single-chunk-over-budget warning ("will run one at a time") is
  # this test's INTENDED regime, but whether it fires depends on the
  # machine's free RAM (the budget floor is a fraction of it), so
  # tolerate rather than expect it.
  got <- suppressWarnings(suppressMessages(collect(out, distributed = TRUE)))
  expect_equal(got, mem, tolerance = 1e-6)
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
