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
  writeLines(c("anon 1", paste("inactive_file", 20000 * mb), paste("active_file", 3000 * mb)),
             file.path(root, "memory.stat"))
  expect_equal(.garry_cgroup_avail_mb(root, self), 160000)
  cg <- garry:::.garry_cgroup_mem(root, self)
  expect_equal(cg$current, 100000)
  expect_equal(cg$limit, 240000)
  expect_equal(cg$active_file, 3000)
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

test_that("the pipeline's compute cap holds what fits, and at least one", {
  expect_identical(garry:::.gd_compute_cap(100, 950, 20L), 9L)
  expect_identical(garry:::.gd_compute_cap(100, 50, 20L), 1L)
  expect_identical(garry:::.gd_compute_cap(100, 1e6, 20L), 20L)
  expect_identical(garry:::.gd_compute_cap(100, NA_real_, 20L), 20L)
})

test_that("a pipeline with budget to spare keeps every band fetching and one strip a daemon", {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1e6)
  fit <- garry:::.gd_fit(6L, 55L, 3660L, 3660L, TRUE, 6L)
  expect_identical(fit$strips, 6L)
  expect_identical(fit$bands, 6L)
})

test_that("a short budget holds fewer cubes and cuts smaller strips", {
  # 2811 MB a cube: budget 7 680 MB holds the mask and one band
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 12800)
  withr::local_options(garry.exec_ram_fraction = 0.6)
  fit <- garry:::.gd_fit(6L, 55L, 3660L, 3660L, TRUE, 6L)
  expect_identical(fit$bands, 1L)
  expect_gt(fit$strips, 6L)
  expect_gte(fit$work_mb, (1 - garry:::.gd_cube_share) * 7680)
  h <- garry:::.gd_strip_bounds(3660L, fit$strips)[[1L]][[2L]]
  expect_lte(6 * garry:::.gd_strip_mb(55L, h, 3660L), fit$work_mb * 1.02)
})

test_that("a budget below one band's cube still opens a band, and says what strips take", {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1000)
  fit <- garry:::.gd_fit(6L, 55L, 3660L, 3660L, FALSE, 6L)
  expect_identical(fit$bands, 1L)
  expect_gt(fit$work_mb, 0)
})

test_that("an asked strip count stands under a short budget", {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 12800)
  expect_identical(garry:::.gd_fit(6L, 55L, 3660L, 3660L, TRUE, 6L, strips = 4L)$strips, 4L)
})

test_that("no reading of RAM leaves the pipeline at full width", {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() NA_real_)
  fit <- garry:::.gd_fit(6L, 55L, 3660L, 3660L, TRUE, 6L)
  expect_identical(fit$strips, 6L)
  expect_identical(fit$bands, 6L)
  expect_true(is.na(fit$work_mb))
})

test_that("rows of many files join into one cube, and a cube splits back", {
  dir <- withr::local_tempdir()
  paths <- file.path(dir, c("a.bin", "b.bin"))
  writeBin(as.raw(1:12), paths[[1L]])
  writeBin(as.raw(101:112), paths[[2L]])
  got <- .Call("garry_read_rows", paths, 4, 4, PACKAGE = "garry")
  expect_identical(got, as.raw(c(5:8, 105:108)))
  out <- file.path(dir, c("c.bin", "d.bin"))
  .Call("garry_write_parts", got, out, PACKAGE = "garry")
  expect_identical(readBin(out[[1L]], "raw", 8L), as.raw(5:8))
  expect_identical(readBin(out[[2L]], "raw", 8L), as.raw(105:108))
  expect_error(.Call("garry_read_rows", paths, 10, 4, PACKAGE = "garry"), "short read")
  expect_error(.Call("garry_read_rows", file.path(dir, "no.bin"), 0, 4, PACKAGE = "garry"), "cannot open")
})

test_that("rows past 2 GiB of a file read", {
  # A 23171-pixel-square f32 plane puts rows there. The file is sparse where
  # that exists, and on Windows, which has no /dev/shm, it sits in tempdir().
  f <- withr::local_tempfile(fileext = ".bin")
  con <- file(f, "wb")
  seek(con, 2^31 + 4, rw = "write")
  writeBin(as.raw(1:4), con)
  close(con)
  expect_identical(.Call("garry_read_rows", f, 2^31 + 4, 4, PACKAGE = "garry"), as.raw(1:4))
})

test_that("store.c takes a 64-bit off_t ahead of every header", {
  # mingw-w64's off_t is 32 bits without it, which no Linux test can see
  src <- test_path("..", "..", "src", "store.c")
  skip_if_not(file.exists(src), "no package source here")
  expect_match(readLines(src, n = 1L), "^#define _FILE_OFFSET_BITS 64\\b")
})

test_that("a program's warm-up compiles a shape no machine could run", {
  fn <- garry:::.gd_lean_fn(NULL, "median", TRUE, NULL, FALSE)
  huge <- c(64L, 20000L, 20000L) # 102 GB, far past this suite's memory
  set <- garry:::.program_set(
    paste0("k-warm-only-", Sys.getpid()),
    fn,
    "f32",
    list(list(huge), list(c(64L, 19999L, 20000L)))
  )
  sp <- list(ck = paste0("k-warm-only-", Sys.getpid()), set = set, dev = "cpu")
  expect_no_error(garry:::.gd_warm_pipeline(list(sp)))
})

test_that("a stage's halo is the deepest path from a member that reads an input", {
  parents <- list(`11` = 10L, `12` = 11L, `13` = c(11L, 10L), `14` = c(12L, 13L))
  testthat::local_mocked_bindings(
    graph_get = function(graph, id) id,
    .node_parents = function(node) parents[[as.character(node)]]
  )
  halos <- c(`11` = 1L, `12` = 2L, `13` = 0L, `14` = 1L)
  expect_identical(garry:::.stage_halo(NULL, 11:14, 10L, halos), 4L)
  # read further down, the upper members add nothing
  expect_identical(garry:::.stage_halo(NULL, 12:14, 11L, halos[-1L]), 3L)
  expect_identical(garry:::.stage_halo(NULL, 11:14, 99L, halos), 0L)
  expect_identical(garry:::.stage_halo(NULL, 11:14, 10L, halos * 0L), 0L)
})
