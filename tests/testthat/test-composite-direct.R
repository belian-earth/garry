# The DEFAULT distributed composite route (.cd_spec ->
# .execute_composite_direct / the fetch-ordered pipeline): offline
# equivalence gates against the single-threaded oracle on a local GTI
# composite — both gd_parallel arms, the morphology (halo) variant, and
# the gd_compute_budget scheduler fall-through. Until this file, the
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
  for (gp in c(TRUE, FALSE)) {
    old <- options(garry.gd_parallel = gp)
    on.exit(options(old), add = TRUE)
    got <- collect(x, distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    .gg_close(got, want)
  }
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

test_that("gd_compute_budget forces the fall-through route, identically", {
  local_pools(2, 2)
  x <- .gg_masked_composite()
  want <- collect(x, distributed = FALSE)
  # Above the budget (with gd_parallel off), .cd_spec refuses and the
  # multi-band composite falls through — to the reduce-decomposition
  # path (the band StackNode is upper IR for .gd_decompose), not the
  # bare scheduler, which route-matrix reaches via composite_direct=FALSE.
  old <- options(garry.gd_compute_budget = 1, garry.gd_parallel = FALSE)
  on.exit(options(old), add = TRUE)
  got <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "gd_reduce")   # route changed...
  .gg_close(got, want)                                 # ...results did not
})

test_that("composite_direct writes to path identically to in-memory", {
  local_pools(2, 2)
  x <- .gg_masked_composite()
  mem <- collect(x, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  path <- tempfile(fileext = ".tif")
  on.exit(unlink(path), add = TRUE)
  collect(x, path = path, nodata = -9999, distributed = TRUE)
  cube <- gdal_read_window(path, 1:2, 0L, 0L, 60L, 40L, nodata = -9999)
  .gg_close(aperm(cube, c(2L, 3L, 1L)), mem)
})
