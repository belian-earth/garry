# Read residency budget. Source/warp store regions live from launch
# until their last CONSUMER retires, so what a read fleet costs is
# residency, not concurrency. Two mechanisms bound it: the planner
# shrinks the coarse read window as the widest stage's input count
# grows, and the scheduler gates read launches on resident bytes.
# Gates: the window shrinks with band count, and a starved gate
# serialises reads (one region at a time, in the task log) without a
# deadlock or a changed answer. The store's price of a region is in
# test-store-residency.R, the fit to available RAM in test-mem-admission.R.

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
  withr::local_options(garry.chunk_target_px = 400, garry.read_budget_mb = 1)

  narrow <- read_px(plan_lazy(wide(2)))
  broad <- read_px(plan_lazy(wide(32)))
  expect_lt(broad, narrow)

  # Residency, not window size, is what the cap holds constant: bands x
  # window stays inside the budget in both plans.
  expect_lte(32 * broad * 4 / 2^20, 1)
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

local({
  local_pools(2, 1)
  f <- fixture_gradient_f32()

  test_that("a read-only pool write keeps its reads inside the read budget", {
    skip_on_cran()
    testthat::local_mocked_bindings(.copy_args = function(...) NULL, .package = "garry") # the pool write
    rd <- function(p) gdal_read_window(p, 1L, 0L, 0L, 60L, 40L)
    out <- withr::local_tempfile(fileext = ".tif")
    log1 <- withr::local_tempfile(fileext = ".csv")
    withr::local_options(garry.chunk_target_px = 400, garry.read_target_px = 400, garry.task_log = log1)
    write_tif(lazy_source(f), out, distributed = TRUE)
    expect_identical(garry_last_route(), "read_only")
    want <- rd(out)
    expect_gt(.max_in_flight(log1), 1L)

    # one region at a time, whether the option or the machine says so
    log2 <- withr::local_tempfile(fileext = ".csv")
    withr::local_options(garry.read_budget_mb = 1e-6, garry.task_log = log2)
    write_tif(lazy_source(f), out, distributed = TRUE)
    expect_identical(.max_in_flight(log2), 1L)
    expect_identical(rd(out), want)

    log3 <- withr::local_tempfile(fileext = ".csv")
    withr::local_options(garry.read_budget_mb = 4096, garry.task_log = log3)
    testthat::local_mocked_bindings(.garry_ram_avail_mb = function() 1e-6)
    write_tif(lazy_source(f), out, distributed = TRUE)
    expect_identical(.max_in_flight(log3), 1L)
    expect_identical(rd(out), want)
  })

  test_that("a chunk over the execution budget warns by class", {
    withr::local_options(
      garry.placement = "rules",
      garry.chunk_target_px = 400,
      garry.exec_ram_fraction = 1e-6
    )
    expect_warning(
      suppressMessages(collect(lazy_source(f) * 2, distributed = TRUE)),
      "single compute chunk",
      class = "garry_memory_warning"
    )
  })

  test_that("a rounding residue in the in-flight sum leaves the compute gate's escape open", {
    # Fused reads of 0.1 MB, three or more in flight, sum back to 3e-17 and
    # not to 0. With the budget then below a read, the next read must still go
    # alone once the last one lands: the run has nothing else in flight.
    fuse_tiles <- garry:::.fuse_tiles
    readings <- 0L
    testthat::local_mocked_bindings(
      .fuse_tiles = function(...) utils::modifyList(fuse_tiles(...), list(ws_mb = 0.1)),
      # the first reading takes the run past the 5 s clock, so the second
      # lands with the first sweep's reads in flight
      .store_budget = function(...) {
        readings <<- readings + 1L
        if (readings == 1L) {
          Sys.sleep(5.1)
          return(list(avail = 1024, pool = 1024, ram_read = 256, read = 256, tight = FALSE))
        }
        list(avail = 1024, pool = 0.05, ram_read = 0, read = 256, tight = FALSE)
      }
    )
    tlog <- withr::local_tempfile(fileext = ".csv")
    # a tight RAM budget cuts this raster into eleven windows
    withr::local_options(
      garry.placement = "cost",
      garry.ram_budget_mb = 0.01,
      garry.read_target_px = 4096,
      garry.chunk_target_px = 4096,
      garry.task_log = tlog
    )
    big <- fixture_tile(t(.fixture_values(256, 256)), nx = 256L, ny = 256L)
    x <- lazy_map(lazy_source(big), fn = function(v) v * 2 + 1)
    got <- suppressMessages(collect(x, distributed = TRUE))
    expect_equal(unclass(got), .fixture_values(256, 256) * 2 + 1, tolerance = 0, ignore_attr = TRUE)
    expect_gte(.max_in_flight(tlog), 3L)
    d <- utils::read.csv(tlog)
    expect_gt(sum(d$event == "launch"), .max_in_flight(tlog))
    expect_gte(readings, 2L)
  })

  test_that("a starved gate serialises a run's reads and its answer holds", {
    # Rules placement keeps the maps on the compute pool, so compute outputs
    # feed the store gate that reads wait on; a run the gates wedged ends in
    # .scheduler_deadlock().
    g <- graph_new()
    x <- reduce_over(
      lazy_stack(lapply(1:4, function(i) lazy_source(f, graph = g) * i), along = "t"),
      "sum",
      "t",
      nan_rm = TRUE
    )
    want <- .fixture_values(60, 40) * (1 + 2 + 3 + 4)
    reads_at_once <- function(...) {
      tlog <- withr::local_tempfile(fileext = ".csv")
      withr::local_options(
        garry.placement = "rules",
        garry.chunk_target_px = 400,
        garry.task_log = tlog,
        ...
      )
      # a chunk over the execution budget warns, depending on free RAM
      got <- suppressWarnings(suppressMessages(collect(x, distributed = TRUE)))
      expect_equal(unclass(got), want, tolerance = 0, ignore_attr = TRUE)
      .max_in_flight(tlog)
    }
    expect_gt(reads_at_once(), 1L)
    # no budget holds less than the widest stage's input set
    expect_gt(reads_at_once(garry.read_budget_mb = 1e-6), 1L)
    # the fit to RAM drives each gate to its floor: one region
    expect_identical(reads_at_once(garry.exec_ram_fraction = 1e-6), 1L)
    # as does a /dev/shm with no room for the store
    testthat::local_mocked_bindings(.garry_shm_free_mb = function() 1)
    expect_identical(reads_at_once(), 1L)
  })
})
