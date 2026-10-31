# The DEFAULT distributed composite route (.cd_spec ->
# .execute_composite_direct / the fetch-ordered pipeline): offline
# equivalence gates against the single-threaded oracle on a local GTI
# composite: the multi-band pipeline, the single-band whole-grid kernel,
# the morphology (halo) variant, and the single-band scheduler fall-through
# past .gd_compute_budget. Until this file, the
# production default composite path had no offline test at all.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

test_that("composite_direct matches the oracle on a masked multi-band composite", {
  local_pools(2, 2)
  x <- .gg_masked_composite()
  p <- collect(x, plan_only = TRUE)
  expect_false(is.null(.cd_spec(p)))          # the fast path matches this shape
  want <- collect(x, distributed = FALSE)
  expect_identical(garry_last_route(), "single")
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  .gg_close(got, want)
})

test_that("a single band runs the whole-grid kernel and matches the oracle", {
  local_pools(2, 2)
  x <- .gg_masked_composite(single = TRUE)
  expect_identical(.cd_spec(collect(x, plan_only = TRUE))$n_bands, 1L)
  want <- collect(x, distributed = FALSE)
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  .gg_close(got, want)
})

test_that("composite_direct matches the oracle with morphology (halo) cleanup", {
  local_pools(2, 2)
  x <- .gg_masked_composite(open = 1L, dilate = 1L)
  p <- collect(x, plan_only = TRUE)
  spec <- .cd_spec(p)
  expect_false(is.null(spec))
  expect_gt(spec$halo, 0L)                    # the morphology rides in the chain
  want <- collect(x, distributed = FALSE)
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  .gg_close(got, want)
})

test_that(".gd_compute_budget sends a heavy single band on, identically", {
  local_pools(2, 2)
  x <- .gg_masked_composite(single = TRUE)
  want <- collect(x, distributed = FALSE)
  # Above the budget .cd_spec refuses a single band, whose whole-grid
  # kernel would run in the host; a multi-band pipeline needs no guard.
  testthat::local_mocked_bindings(.gd_compute_budget = 1)
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "scheduler")   # route changed...
  .gg_close(got, want)                                 # ...results did not
  y <- .gg_masked_composite()
  expect_false(is.null(.cd_spec(collect(y, plan_only = TRUE))))
})

test_that("composite_direct writes to path identically to in-memory", {
  local_pools(2, 2)
  x <- .gg_masked_composite()
  mem <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  path <- tempfile(fileext = ".tif")
  on.exit(unlink(path), add = TRUE)
  write_tif(x, path, nodata = -9999, distributed = TRUE)
  cube <- gdal_read_window(path, 1:2, 0L, 0L, 60L, 40L, nodata = -9999)
  .gg_close(aperm(cube, c(2L, 3L, 1L)), mem)
})

test_that("bands with different per-slice fns do not take the fast path", {
  local_pools(2, 2)
  gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  g <- graph_new()
  sl <- function(gti) {
    list(.gg_slice(gti, "s1", g), .gg_slice(gti, "s2", g))
  }
  a <- sl(gA)
  b <- sl(gB)
  minus <- lazy_stack(Map(`-`, a, b))
  times <- lazy_stack(Map(`*`, a, b))
  x <- lazy_stack(
    list(
      d = reduce_over(minus, "mean", "t"),
      p = reduce_over(times, "mean", "t")
    ),
    along = "band"
  )
  expect_null(.cd_spec(collect(x, plan_only = TRUE)))
  want <- collect(x, distributed = FALSE)
  got <- collect(x, distributed = TRUE)
  .gg_close(got, want)
})

test_that("GTI sources the fast routes cannot read themselves fall through", {
  gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
  src <- function(filter = "slice = 's1'", sort_asc = TRUE, band = 1L) {
    lazy_source(
      paste0("GTI:", gA),
      band = band,
      open_options = gti_open_options(
        .gg_grid,
        filter = filter,
        sort_field = "datetime",
        sort_asc = sort_asc
      ),
      grid = .gg_grid,
      block_dim = c(60L, 40L)
    )
  }
  n <- function(lr) graph_get(lr@graph, lr@node_id)
  expect_true(.gd_source_ok(n(src())))
  expect_false(.gd_source_ok(n(src(filter = "datetime > '2020'"))))
  expect_false(.gd_source_ok(n(src(sort_asc = FALSE))))
  expect_identical(.gti_slice_of("FILTER=slice = 's1'"), "s1")
  expect_null(.gti_slice_of("FILTER=slice = 's1' AND x = 2"))
  expect_true(is.na(.gti_slice_of(character(0))))
})

test_that("a failed warp is the run's failure", {
  bad <- structure("slice warp failed: a.tif", class = c("miraiError", "errorValue"))
  err <- expect_error(.gd_check_fetch(list(list(tw = 1), bad), "band 1"), class = "garry_read_error")
  expect_match(conditionMessage(err), "1/2 band 1 warps failed", fixed = TRUE)
  expect_match(conditionMessage(err), "a.tif", fixed = TRUE)
  expect_no_error(.gd_check_fetch(list(list(tw = 1)), "band 1"))
})

test_that("a failed slice warp names its source and leaves no slice", {
  withr::local_options(garry.read_retry = 0L)
  bin <- withr::local_tempfile(fileext = ".bin")
  j <- list(locs = "/nonexistent/ghost.tif", dt = 1, nodata = numeric(0), resampling = "near", bin = bin)
  k <- list(nx = 4L, ny = 4L, gtstr = "0/10/0/40/0/-10", wkt = gdalraster::srs_to_wkt("EPSG:3857"))
  err <- expect_error(suppressMessages(.cd_fetch_warp(j, k)), class = "garry_read_error")
  expect_match(conditionMessage(err), "ghost.tif", fixed = TRUE)
  expect_false(file.exists(bin))
})

test_that("a composite warps onto the declared grid, to the last digit", {
  gti <- .gg_gti(list(s1 = .gg_val(0)))
  p <- plan_lazy(.gg_slice(gti, "s1", graph_new()))
  g <- grid_spec("EPSG:3857",
                 extent = c(-13627665.27123, 500010.123456, -13627065.27123, 500410.123456),
                 dims = c(60L, 40L), dtype = "f32")
  gt <- as.numeric(strsplit(.gd_build_jobs(p, g, tempdir())$K$gtstr, "/")[[1L]])
  expect_identical(gt, g@transform)
})

test_that("a slice with no items fails as a read, saying so", {
  expect_error(
    garry:::.cd_fetch_warp(list(locs = character(0)), list(nx = 1L, ny = 1L)),
    "no items",
    class = "garry_read_error"
  )
})
