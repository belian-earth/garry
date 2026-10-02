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
