# Decision D6 lock: binary ops auto-merge graphs; identical sources dedup.

test_that("a + b across separate graphs works and dedups the source", {
  a <- lazy_source_stub("x.tif")
  b <- lazy_source_stub("x.tif")           # separate graph, same source
  expect_false(identical(a@graph@nodes, b@graph@nodes))

  c <- a + b
  expect_true(S7::S7_inherits(c, LazyRaster))
  # One SourceNode only: the import recognised the identical source.
  ids <- graph_ids(c@graph)
  sources <- Filter(function(i) S7::S7_inherits(graph_get(c@graph, i), SourceNode), ids)
  expect_length(sources, 1L)
  # Map node has the same parent twice.
  map <- graph_get(c@graph, c@node_id)
  expect_identical(map@parents, c(sources[[1]], sources[[1]]))
})

test_that("distinct sources stay distinct after merge", {
  a <- lazy_source_stub("x.tif")
  b <- lazy_source_stub("y.tif")
  c <- a + b
  ids <- graph_ids(c@graph)
  sources <- Filter(function(i) S7::S7_inherits(graph_get(c@graph, i), SourceNode), ids)
  expect_length(sources, 2L)
  expect_identical(graph_toposort(c@graph), sort(ids))
})

test_that("diamond sharing survives import", {
  # b's graph: src -> m1, src -> m2, m1 + m2 (diamond on one source).
  b0 <- lazy_source_stub("y.tif")
  m1 <- b0 + 1
  m2 <- b0 * 2
  d  <- m1 + m2

  a <- lazy_source_stub("x.tif")
  out <- a + d

  g <- out@graph
  ids <- graph_ids(g)
  sources <- Filter(function(i) S7::S7_inherits(graph_get(g, i), SourceNode), ids)
  expect_length(sources, 2L)   # x.tif and y.tif exactly once each

  # The imported diamond still shares its source: exactly one y.tif node,
  # and both imported maps point at it.
  y_src <- Filter(function(i) {
    n <- graph_get(g, i)
    S7::S7_inherits(n, SourceNode) && n@path == "y.tif"
  }, ids)[[1]]
  maps_on_y <- Filter(function(i) {
    n <- graph_get(g, i)
    S7::S7_inherits(n, MapNode) && y_src %in% n@parents
  }, ids)
  expect_length(maps_on_y, 2L)

  expect_identical(graph_toposort(g), sort(ids))
})

test_that("the right operand remains usable after a merge", {
  a <- lazy_source_stub("x.tif")
  b <- lazy_source_stub("y.tif")
  invisible(a + b)
  # b's own graph is untouched; further composition on b still works.
  b2 <- b * 3
  expect_true(S7::S7_inherits(b2, LazyRaster))
  expect_length(graph_ids(b@graph), 2L)   # source + map, no leakage from a
})

test_that("same-graph operands do not import", {
  a <- lazy_source_stub("x.tif")
  b <- lazy_source_stub("y.tif", graph = a@graph)
  c <- a + b
  expect_length(graph_ids(c@graph), 3L)   # 2 sources + map, nothing copied
})
