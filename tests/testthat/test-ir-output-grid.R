# Decision D7 lock: named dims and the Reduce grid algebra.

.stub_grid_3d <- function(dtype = "f32") {
  # 100x80 spatial, 7 time steps, 0.5-degree pixels.
  GridSpec(crs = "EPSG:4326",
           transform = c(0, 0.5, 0, 40, 0, -0.5),
           extent = c(0, 0, 50, 40),
           dims = c(x = 100L, y = 80L, t = 7L),
           dtype = dtype)
}

test_that("dims are named automatically and validated", {
  g <- grid_spec("EPSG:4326", c(0, -10, 10, 0), c(10L, 10L))
  expect_identical(names(g@dims), c("x", "y"))
  g3 <- .stub_grid_3d()
  expect_identical(names(g3@dims), c("x", "y", "t"))
  expect_error(
    GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, -1),
             extent = c(0, -10, 10, 0), dims = c(a = 10L, b = 10L),
             dtype = "f32"),
    "must be named"
  )
})

test_that("reduce over t drops the dim, keeps spatial identity", {
  pg <- .stub_grid_3d()
  rg <- garry:::.reduce_grid(pg, "mean", "t")
  expect_identical(names(rg@dims), c("x", "y"))
  expect_identical(rg@transform, pg@transform)
  expect_identical(rg@extent, pg@extent)
  expect_identical(rg@dtype, "f32")
})

test_that("reduce over x and y collapses axes, preserves extent", {
  pg <- .stub_grid_3d()
  rg <- garry:::.reduce_grid(pg, "mean", c("x", "y"))
  expect_identical(unname(rg@dims[c("x", "y")]), c(1L, 1L))
  expect_identical(rg@dims[["t"]], 7L)
  expect_identical(rg@extent, pg@extent)
  # Resolution rescaled to the full span.
  expect_identical(rg@transform[2], 0.5 * 100)
  expect_identical(rg@transform[6], -0.5 * 80)
})

test_that("reduce dtype rules: float ops promote ints; count/any typed", {
  pg_i <- .stub_grid_3d("i16")
  expect_identical(garry:::.reduce_grid(pg_i, "mean", "t")@dtype, "f32")
  expect_identical(garry:::.reduce_grid(pg_i, "median", "t")@dtype, "f32")
  expect_identical(garry:::.reduce_grid(pg_i, "sum", "t")@dtype, "i16")
  expect_identical(garry:::.reduce_grid(pg_i, "max", "t")@dtype, "i16")
  expect_identical(garry:::.reduce_grid(pg_i, "count", "t")@dtype, "i32")
  expect_identical(garry:::.reduce_grid(pg_i, "any", "t")@dtype, "pred")
  pg_f <- .stub_grid_3d("f64")
  expect_identical(garry:::.reduce_grid(pg_f, "mean", "t")@dtype, "f64")
})

test_that("reduce over unknown dims errors", {
  pg <- grid_spec("EPSG:4326", c(0, -10, 10, 0), c(10L, 10L))
  expect_error(garry:::.reduce_grid(pg, "mean", "t"), "missing dim")
})

test_that("full pipeline grids: Source -> Map -> Focal -> Reduce", {
  a <- lazy_source("x.tif")            # stub: 100x100 f32, EPSG:4326
  m <- a + 1
  f <- focal(m, fn = function(n) mean(n), radius = 1L)
  r <- reduce_over(f, "mean", c("x", "y"))

  expect_identical(m@grid@dims, a@grid@dims)
  expect_identical(f@grid@dims, a@grid@dims)
  expect_identical(unname(r@grid@dims), c(1L, 1L))
  expect_identical(r@grid@extent, a@grid@extent)
  # output_grid on the stored nodes agrees with the cached grids.
  rn <- graph_get(r@graph, r@node_id)
  expect_true(grid_equal(output_grid(rn, list(f@grid)), r@grid))
})

test_that("reduce_over rejects unknown ops at node construction", {
  a <- lazy_source("x.tif")
  expect_error(reduce_over(a, "medoid", c("x", "y")), "op")
})
