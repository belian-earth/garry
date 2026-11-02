# A custom reducer over every band runs on the direct route: one kernel, one
# block or several, the same cells as the scheduler.

.gj_cube <- function(open = 1L, dilate = 1L) {
  x <- .gg_masked_dataset(open = open, dilate = dilate)
  lazy_stack(list(V1 = x[["V1"]], V2 = x[["V2"]]), along = "band")
}

.gj_scheduler <- function(x) {
  testthat::local_mocked_bindings(.cd_spec = function(plan) NULL, .package = "garry")
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "scheduler")
  got
}

local({
  local_pools(2, 2)

  test_that("a joint reducer takes the direct route and gives the scheduler's cells", {
    for (fn in list(geomedian(4L), medoid(4L))) {
      x <- reduce_over(.gj_cube(), fn, over = "t")
      want <- .gj_scheduler(x)
      got <- collect(x, distributed = TRUE)
      expect_identical(garry_last_route(), "composite_direct")
      expect_identical(got, want)
    }
  })

  test_that("a reducer declaring anything but f32 leaves the direct route", {
    cube <- .gj_cube()
    plain <- reduce_over(cube, function(a, margin) g_cast(g_count(a, margin), "f32"), over = "t")
    want <- .gj_scheduler(plain)
    expect_setequal(as.vector(want), c(1, 2))
    expect_identical(collect(plain, distributed = TRUE), want)
    expect_identical(garry_last_route(), "composite_direct")
    counted_as <- function(dt) {
      force(dt)
      function(a, margin) g_cast(g_count(a, margin), dt)
    }
    for (dt in c("i32", "f64")) {
      x <- reduce_over(cube, counted_as(dt), over = "t")
      expect_identical(x@grid@dtype, dt)
      expect_identical(as.numeric(collect(x, distributed = TRUE)), as.numeric(want), info = dt)
      expect_identical(garry_last_route(), "scheduler", info = dt)
    }
  })

  test_that("a logical reducer stores 0/1 on the direct route", {
    x <- reduce_over(.gj_cube(), function(a, margin) g_count(a, margin) > 1L, over = "t")
    want <- .gj_scheduler(x)
    expect_setequal(as.vector(want), c(0, 1))
    expect_identical(collect(x, distributed = TRUE), want)
    expect_identical(garry_last_route(), "composite_direct")
  })

  test_that("free RAM moves no bit of a joint reducer", {
    x <- reduce_over(.gj_cube(), geomedian(4L), over = "t")
    want <- collect(x, distributed = TRUE)
    for (avail in c(1e6, 3000, 50)) {
      testthat::local_mocked_bindings(.garry_ram_avail_mb = function() avail, .package = "garry")
      expect_identical(collect(x, distributed = TRUE), want, info = avail)
    }
  })

  test_that("blocks and strips move no bit of a geomedian, and tmpfs ends empty", {
    x <- reduce_over(.gj_cube(), geomedian(4L), over = "t")
    want <- collect(x, distributed = TRUE)
    for (shape in list(c(1L, 40L), c(3L, 40L), c(2L, 16L), c(3L, 7L), c(1L, 3L))) {
      testthat::local_mocked_bindings(
        .gd_fit = function(...) list(strips = shape[[1L]], bands = 1L, work_mb = 1e6),
        .gd_block_rows = function(spec) shape[[2L]],
        .package = "garry"
      )
      expect_identical(collect(x, distributed = TRUE), want, info = paste(shape, collapse = " x "))
    }
    plan <- collect(x, plan_only = TRUE)
    tmp <- withr::local_tempdir()
    res <- garry:::.gd_block_results(plan, .cd_spec(plan), tmp, garry:::.gd_log_open())
    expect_length(res, 2L)
    expect_length(list.files(tmp), 0L)
  })

  test_that("a self-masked cube reads its band and mask through their own windows", {
    # with a halo the mask reads rows past the block, into a file of its own
    ds <- .gg_dated_dataset("self", open = 1L, dilate = 1L)
    x <- reduce_over(lazy_stack(list(V1 = ds[["V1"]], V2 = ds[["V2"]]), along = "band"), geomedian(4L), over = "t")
    plan <- collect(x, plan_only = TRUE)
    spec <- .cd_spec(plan)
    expect_gt(spec$halo, 0L)
    expect_identical(spec$fmask_srcs, spec$band_srcs[[1L]])
    want <- .gj_scheduler(x)
    expect_gt(sum(is.nan(want)), 0L)
    expect_identical(collect(x, distributed = TRUE), want)
    expect_identical(garry_last_route(), "composite_direct")
    for (rows in c(16L, 7L)) {
      testthat::local_mocked_bindings(.gd_block_rows = function(spec) rows, .package = "garry")
      expect_identical(collect(x, distributed = TRUE), want, info = rows)
    }
    tmp <- withr::local_tempdir()
    res <- garry:::.gd_block_results(plan, spec, tmp, garry:::.gd_log_open())
    expect_length(res, 2L)
    expect_length(list.files(tmp), 0L)
  })

  test_that("an unmasked cube reduces jointly too", {
    x <- .gg_unmasked_cube()
    r <- reduce_over(x, geomedian(4L), over = "t")
    want <- .gj_scheduler(r)
    expect_identical(collect(r, distributed = TRUE), want)
    expect_identical(garry_last_route(), "composite_direct")
  })
})

test_that("a block is a whole multiple of the fixed height and follows no live RAM", {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() stop("not asked"))
  sp <- list(band_srcs = rep(list(seq_len(55L)), 6L), fmask_srcs = seq_len(55L),
             grid = grid_spec("EPSG:32755", extent = c(0, 0, 36600, 36600), dims = c(3660L, 3660L)))
  rows <- garry:::.gd_block_rows(sp)
  expect_identical(rows %% garry:::.gd_block_tile, 0L)
  expect_gte(rows, garry:::.gd_block_tile)
})

test_that("a joint strip's height comes from the plan and the option alone", {
  testthat::local_mocked_bindings(.garry_ram_avail_mb = function() stop("not asked"))
  withr::local_options(garry.ram_budget_mb = 512)
  expect_identical(garry:::.gd_joint_rows(55L, 3660L, 34), 4L)
  expect_identical(garry:::.gd_joint_rows(55L, 1e6L, 34), 1L)
})

test_that("a fetch plane starts NaN, writes out and frees itself", {
  p <- .Call("garry_plane_new", 6, PACKAGE = "garry")
  f <- withr::local_tempfile()
  .Call("garry_plane_write", p, f, PACKAGE = "garry")
  expect_identical(file.size(f), 24)
  expect_true(all(is.nan(readBin(f, "numeric", n = 6L, size = 4L))))
  expect_error(.Call("garry_plane_write", p, f, PACKAGE = "garry"), "written already")
})
