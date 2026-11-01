# The DEFAULT distributed composite route (.cd_spec ->
# .execute_composite_direct / the fetch-ordered pipeline): what selects it
# and how its parts fail. test-route-matrix.R holds its results to plain R;
# the strip decomposition and morphology live in test-gd-tail.R.

test_that(".gd_compute_budget sends a heavy single band to the scheduler", {
  p <- collect(.gg_masked_composite(single = TRUE), plan_only = TRUE)
  expect_identical(.cd_spec(p)$n_bands, 1L)
  # Above the budget .cd_spec refuses a single band, whose whole-grid
  # kernel would run in the host; a multi-band pipeline needs no guard.
  testthat::local_mocked_bindings(.gd_compute_budget = 1)
  expect_null(.cd_spec(p))
  expect_null(.gd_decompose(p))
  expect_false(is.null(.cd_spec(collect(.gg_masked_composite(), plan_only = TRUE))))
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
