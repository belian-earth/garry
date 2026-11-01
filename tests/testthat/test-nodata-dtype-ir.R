# Decision D8 (IR half) + D3 in action: nodata promotion at source,
# dtype promotion through binary ops and reductions.

# Helper: stub source with a chosen dtype.
.lazy_source_typed <- function(path, dtype, graph = graph_new()) {
  lr <- lazy_source_stub(path, graph = graph)
  # Rewrite the stub node's dtype (the real adapter reads it from GDAL).
  n <- graph_get(lr@graph, lr@node_id)
  n@grid <- garry:::.grid_retype(n@grid, dtype)
  graph_replace(lr@graph, lr@node_id, n)
  LazyRaster(graph = lr@graph, node_id = lr@node_id, grid = n@grid)
}

test_that("an integer source with nodata promotes to the float that holds it", {
  a <- lazy_source(fixture_tile(1, "Int16", nodata = -9999))
  expect_identical(a@grid@dtype, "f32")
  expect_identical(graph_get(a@graph, a@node_id)@nodata, -9999)
  # f32 has no room for every 32-bit integer
  expect_identical(lazy_source(fixture_tile(1, "Int32", nodata = -9999))@grid@dtype, "f64")
})

test_that("integer source without nodata keeps its dtype", {
  expect_identical(lazy_source(fixture_tile(1, "Int16"))@grid@dtype, "i16")
})

test_that("float source with nodata keeps float dtype", {
  a <- lazy_source(fixture_tile(1, "Float64", nodata = -3.4e38))
  expect_identical(a@grid@dtype, "f64")
})

test_that("binary op dtype promotion flows through MapNodes", {
  g <- graph_new()
  a <- .lazy_source_typed("x.tif", "f32", graph = g)
  b <- .lazy_source_typed("y.tif", "i32", graph = g)
  expect_identical((a + b)@grid@dtype, "f32")
  expect_identical((a * b)@grid@dtype, "f32")

  c <- .lazy_source_typed("c.tif", "i16", graph = g)
  d <- .lazy_source_typed("d.tif", "i32", graph = g)
  expect_identical((c + d)@grid@dtype, "i32")
  # Division always floats (D3).
  expect_identical((c / d)@grid@dtype, "f32")
})

test_that("scalar dtypes follow the kernel: doubles and division float", {
  a <- .lazy_source_typed("x.tif", "i16")
  expect_identical((a + 1L)@grid@dtype, "i16")
  expect_identical((2L * a)@grid@dtype, "i16")
  expect_identical((a + 1)@grid@dtype, "f32")
  expect_identical((2 * a)@grid@dtype, "f32")
  expect_identical((a / 2L)@grid@dtype, "f32")
  b <- .lazy_source_typed("y.tif", "f64")
  expect_identical((b + 1)@grid@dtype, "f64")
})

test_that("mean reduction promotes integer input to f32", {
  a <- .lazy_source_typed("x.tif", "i32")
  r <- reduce_over(a, "mean", c("x", "y"))
  expect_identical(r@grid@dtype, "f32")
  s <- reduce_over(a, "sum", c("x", "y"))
  expect_identical(s@grid@dtype, "i64")
})

test_that("g_cast oracle respects target family semantics", {
  x <- matrix(c(-1.7, 0, 2.9, NaN), 2, 2)
  expect_identical(g_cast(x, "i32"), matrix(c(-1, 0, 2, NaN), 2, 2))
  expect_identical(g_cast(x, "pred")[1, 1], TRUE)
  expect_identical(g_cast(x, "pred")[2, 1], FALSE)
  expect_identical(g_cast(x, "f64"), x)
})
