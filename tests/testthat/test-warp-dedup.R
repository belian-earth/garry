# Sharing identical warp-on-read stages between consumers. graph_import()
# dedups SourceNodes but copies derived nodes, so a band used in two
# subexpressions used to carry one WarpNode per use.

n_warps <- function(x) {
  sum(vapply(collect(x, plan_only = TRUE)@stages,
             function(s) s@kind == "warp", logical(1)))
}

without_dedup <- function(expr) {
  old <- options(garry.warp_dedup = FALSE)
  on.exit(options(old))
  force(expr)
}

target_of <- function(f, fact = 2L) {
  g <- gdal_grid_spec(f)$grid
  r <- g@transform[[2L]] * fact
  x0 <- g@transform[[1L]]
  y0 <- g@transform[[4L]]
  nx <- g@dims[["x"]] %/% fact
  ny <- g@dims[["y"]] %/% fact
  grid_spec(g@crs, extent = c(x0, y0 - ny * r, x0 + nx * r, y0),
            dims = c(nx, ny))
}

test_that("a band used in two subexpressions is read once", {
  mb <- fixture_multiband()
  target <- target_of(mb$path)

  mk <- function() {
    x <- align(lazy_source(mb$path, band = 1L), target)
    y <- align(lazy_source(mb$path, band = 2L), target)
    (x - y) / (x + y)
  }

  expect_identical(n_warps(mk()), 2L)
  expect_identical(without_dedup(n_warps(mk())), 3L)
})

test_that("dedup does not change the result", {
  mb <- fixture_multiband()
  target <- target_of(mb$path)

  mk <- function() {
    x <- align(lazy_source(mb$path, band = 1L), target)
    y <- align(lazy_source(mb$path, band = 2L), target)
    lazy_stack(list((x - y) / (x + y), (y - x) / (y + x)), along = "band")
  }

  got <- collect(mk())
  want <- without_dedup(collect(mk()))
  expect_identical(got, want)
})

test_that("warps differing in grid or resampling are not shared", {
  f <- fixture_gradient_f32()
  t1 <- target_of(f, 2L)
  t2 <- target_of(f, 3L)

  # same source and grid, different resampling
  a <- align(lazy_source(f), t1, resampling = "bilinear")
  b <- align(lazy_source(f), t1, resampling = "near")
  expect_identical(n_warps(a + b), 2L)

  # same source and resampling, different grid: grids differ so the sum
  # is not even expressible, but each alone keeps its own warp
  expect_identical(n_warps(align(lazy_source(f), t1)), 1L)
  expect_identical(n_warps(align(lazy_source(f), t2)), 1L)
})

test_that("the pass is idempotent and leaves a reused graph valid", {
  mb <- fixture_multiband()
  target <- target_of(mb$path)

  x <- align(lazy_source(mb$path, band = 1L), target)
  y <- align(lazy_source(mb$path, band = 2L), target)
  expr <- (x - y) / (x + y)

  first <- n_warps(expr)
  second <- n_warps(expr)          # same graph, planned twice
  expect_identical(first, 2L)
  expect_identical(second, 2L)

  # the rewired-away warp is still a valid root of its own
  expect_identical(dim(collect(y)), c(target@dims[["y"]], target@dims[["x"]]))
  expect_equal(collect(expr), collect(expr))
})

test_that("a warp that is itself a requested sink stays canonical", {
  mb <- fixture_multiband()
  target <- target_of(mb$path)

  x <- align(lazy_source(mb$path, band = 1L), target)
  y <- align(lazy_source(mb$path, band = 2L), target)
  res <- collect(list(band = y, ratio = (x - y) / (x + y)))

  expect_named(res, c("band", "ratio"), ignore.order = TRUE)
  expect_identical(res$band, collect(y))
})
