# Read residency budget. Source/warp store regions live from launch
# until their last CONSUMER retires, so what a read fleet costs is
# residency, not concurrency. Two mechanisms bound it: the planner
# shrinks the coarse read window as the widest stage's input count
# grows, and the scheduler gates read launches on resident bytes.
# Gates: the window shrinks with band count, a budget far below one
# stage's input set still completes (escape hatch, no deadlock), and
# results are identical to single-threaded whatever the budget.


test_that("coarse read window shrinks with the widest stage's inputs", {
  f <- fixture_gradient_f32()
  wide <- function(n) {
    g <- graph_new()
    reduce_over(lazy_stack(lapply(seq_len(n), function(i)
      lazy_source(f, graph = g) * i), along = "band"),
      "sum", "band", nan_rm = TRUE)
  }
  read_px <- function(p) {
    s <- Filter(function(s) s@kind == "source_read", p@stages)[[1L]]
    prod(as.numeric(s@chunks@chunk_dim))
  }
  old <- options(garry.chunk_target_px = 400, garry.read_budget_mb = 1)
  on.exit(options(old), add = TRUE)

  narrow <- read_px(plan_lazy(wide(2)))
  broad <- read_px(plan_lazy(wide(32)))
  expect_true(broad < narrow)

  # Residency, not window size, is what the cap holds constant: bands x
  # window stays inside the budget in both plans.
  expect_lte(32 * broad * 4 / 2^20, 1)
})

test_that("eager release: cross-stage intermediates drop, results identical", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  local_pools(2, 1, gdal_config = TRUE)

  # A stage-crossing pipeline (map -> t-reduce -> map) whose
  # intermediate compute outputs must be droppable mid-run without
  # perturbing the streamed result.
  f <- fixture_gradient_f32()
  g <- graph_new()
  stk <- lazy_stack(lapply(1:6, function(i)
    lazy_source(f, graph = g) * i), along = "t")
  out <- reduce_over(stk, "median", "t", nan_rm = TRUE) * 2 + 1
  dir <- withr::local_tempdir("relstream")
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  write_tif(out, file.path(dir, "out.tif"), distributed = TRUE)
  mem <- collect(out, distributed = FALSE)
  d <- methods::new(gdalraster::GDALRaster, file.path(dir, "out.tif"))
  got <- matrix(d$read(1, 0, 0, 60, 40, 60, 40), 40, 60, byrow = TRUE)
  d$close()
  expect_equal(got, unclass(mem), tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a read budget below one stage's input set still completes", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  local_pools(2, 1, gdal_config = TRUE)

  f <- fixture_gradient_f32()
  g <- graph_new()
  lr <- reduce_over(lazy_stack(lapply(1:8, function(i)
    lazy_source(f, graph = g) * i), along = "band"),
    "sum", "band", nan_rm = TRUE)
  p <- plan_lazy(lr)
  single <- execute_plan(p)

  for (budget in c(1e-6, 1e6)) {
    old <- options(garry.chunk_target_px = 400,
                   garry.read_budget_mb = budget)
    dist <- execute_plan_mirai(plan_lazy(lr))
    options(old)
    expect_equal(dist, single, tolerance = 1e-12,
                 label = sprintf("read_budget_mb = %g", budget))
  }
})

test_that("the store budget follows RAM, /dev/shm and the cgroup", {
  mem <- function(ram, shm, cg) {
    testthat::local_mocked_bindings(
      .garry_ram_avail_mb = function() ram,
      .garry_shm_free_mb = function() shm,
      .garry_cgroup_avail_mb = function(...) cg
    )
    garry:::.store_budget(4096, 10, 100, 0.6)
  }
  # plenty of everything: the configured cap
  b <- mem(1e5, 1e5, NA_real_)
  expect_equal(b$read, 4096)
  expect_equal(b$pool, 6e4)
  expect_false(b$tight)
  # a third of the RAM pool
  expect_equal(mem(3000, 1e5, NA_real_)$read, 600)
  # what is resident plus what the mount holds past the headroom
  b <- mem(1e5, 1000, NA_real_)
  expect_equal(b$read, 100 + 1000 - 512)
  expect_equal(b$ram_read, 4096)
  # the cgroup's headroom binds tmpfs pages too, and with no mount alone
  expect_equal(mem(1e5, 1e5, 1000)$read, 100 + 1000 - 512)
  expect_equal(mem(1e5, NA_real_, 1000)$read, 100 + 1000 - 512)
  # below the headroom the store must flush, and one region still fits
  b <- mem(1e5, 100, NA_real_)
  expect_true(b$tight)
  expect_equal(b$read, 10)
  expect_equal(mem(1, 1e5, NA_real_)$read, 10)
  # no RAM reading leaves the run on its configured budget
  expect_null(mem(NA_real_, 1e5, NA_real_))
})

test_that("a read-only pool write keeps its reads inside the read budget", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  skip_on_cran()
  local_pools(2, 1)
  f <- fixture_gradient_f32()
  rd <- function(p) gdal_read_window(p, 1L, 0L, 0L, 60L, 40L)
  max_reads <- function(tlog) {
    d <- read.csv(tlog)
    d <- d[d$event %in% c("launch", "done") & startsWith(d$key, "s"), ]
    max(cumsum(ifelse(d$event == "launch", 1L, -1L)))
  }
  out <- withr::local_tempfile(fileext = ".tif")
  log1 <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.chunk_target_px = 400, garry.task_log = log1)
  write_tif(lazy_source(f), out, distributed = TRUE)
  expect_identical(garry_last_route(), "read_only")
  want <- rd(out)
  expect_gt(max_reads(log1), 1L)

  # one region at a time, whether the option or the machine says so
  log2 <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.read_budget_mb = 1e-6, garry.task_log = log2)
  write_tif(lazy_source(f), out, distributed = TRUE)
  expect_identical(max_reads(log2), 1L)
  expect_identical(rd(out), want)

  log3 <- withr::local_tempfile(fileext = ".csv")
  withr::local_options(garry.read_budget_mb = 4096, garry.task_log = log3)
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1e-6)
  write_tif(lazy_source(f), out, distributed = TRUE)
  expect_identical(max_reads(log3), 1L)
  expect_identical(rd(out), want)
})
