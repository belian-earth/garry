test_that("graph build and topo-sort works", {
  g  <- graph_new()
  gs <- GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, -1),
                 extent = c(0, -10, 10, 0), dims = c(10L, 10L), dtype = "f32")

  src_id   <- graph_add(g, SourceNode, parents = integer(0), grid = gs,
                        path = "x.tif", band = 1L)
  map_id   <- graph_add(g, MapNode,    parents = src_id, grid = gs,
                        fn = function(x) x + 1)
  focal_id <- graph_add(g, FocalNode,  parents = map_id, grid = gs,
                        fn = function(n) mean(n), radius = 1L,
                        boundary = "reflect")
  red_id   <- graph_add(g, ReduceNode, parents = focal_id, grid = gs,
                        fn = function(x) mean(x), over = "x")

  order <- graph_toposort(g)
  expect_equal(order, c(src_id, map_id, focal_id, red_id))
  expect_true(is_barrier(graph_get(g, red_id)))
  expect_false(is_barrier(graph_get(g, map_id)))
  expect_equal(required_halo(graph_get(g, focal_id)), 1L)
})

test_that("LazyRaster composes via operators", {
  a <- lazy_source("x.tif")
  b <- lazy_source("y.tif", graph = a@graph)   # share the graph
  c <- a + b
  d <- focal(c, fn = function(n) mean(n), radius = 1L)

  expect_true(S7::S7_inherits(d, LazyRaster))
  expect_true(grid_equal(d@grid, a@grid))
  expect_equal(length(graph_ids(a@graph)), 4L)   # 2 sources + map + focal
})
