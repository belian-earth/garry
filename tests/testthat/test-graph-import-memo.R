# graph_import(): a foreign node referenced several times imports ONCE.
# Otherwise a lazy raster built on graph A and consumed k times on graph B
# plants k read+compute chains.

test_that("re-importing the same foreign node reuses the local copy", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)                          # its own graph
  p <- lazy_map(a, fn = function(x) x * 2 + 1, dtype = "f32")
  q <- lazy_map(p, fn = function(x) sqrt(abs(x)), dtype = "f32")

  g <- graph_new()
  n0 <- length(graph_ids(g))
  id1 <- graph_import(g, p@graph, p@node_id)
  n1 <- length(graph_ids(g))
  expect_gt(n1, n0)
  id2 <- graph_import(g, p@graph, p@node_id)   # same root again
  expect_identical(id2, id1)
  expect_identical(length(graph_ids(g)), n1)   # nothing new planted
  # a descendant of an imported node reuses the imported ancestry
  id3 <- graph_import(g, q@graph, q@node_id)
  expect_identical(length(graph_ids(g)), n1 + 1L)
  expect_identical(graph_get(g, id3)@parents, id1)
})

test_that("consumers of one lazy raster on another graph share one chain", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  p <- lazy_map(a, fn = function(x) x * 2, dtype = "f32")
  g <- graph_new()
  b <- lazy_source(f, band = 1L, graph = g)
  # three consumers on g referencing the foreign p
  c1 <- lazy_map(b, p, fn = function(u, v) u + v, dtype = "f32")
  c2 <- lazy_map(b, p, fn = function(u, v) u - v, dtype = "f32")
  c3 <- lazy_map(p, b, fn = function(v, u) v * u, dtype = "f32")
  pl <- plan_lazy(list(c1 = c1, c2 = c2, c3 = c3))
  # the plan holds ONE copy of p's map node
  maps <- Filter(function(id) S7::S7_inherits(graph_get(pl@graph, id), MapNode),
                 graph_ids(pl@graph))
  expect_identical(length(maps), 4L)          # p + c1 + c2 + c3
  # and the results are right
  res <- execute_plan(pl)
  m <- .fixture_values(60, 40)
  expect_equal(res$c1, m + m * 2, tolerance = 1e-6, ignore_attr = TRUE)
  expect_equal(res$c3, (m * 2) * m, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("the memo survives a source graph's env address being recycled", {
  # Keyed on the env address this returned a dead graph's import for a
  # fresh graph allocated at the same address (24 of 3000 in a tight
  # loop); keyed on the graph uid it never can. A graph read back is the
  # same graph at a new address, which shows an address key on every run,
  # where waiting for an address to recycle shows it only by luck.
  f <- fixture_gradient_f32()
  p <- lazy_map(lazy_source(f), fn = function(x) x * 2, dtype = "f32")
  g <- graph_new()
  id <- graph_import(g, p@graph, p@node_id)
  planted <- length(graph_ids(g))
  copy <- unserialize(serialize(p@graph, NULL))
  expect_false(identical(copy@nodes, p@graph@nodes))
  expect_identical(graph_import(g, copy, p@node_id), id)
  expect_identical(length(graph_ids(g)), planted)
  # fresh graphs never share a key, though each one's node ids are the same
  proto <- graph_get(lazy_source(f)@graph, 1L)
  g <- graph_new()
  for (i in seq_len(20L)) {
    s <- graph_new()
    n <- proto
    n@path <- paste0("p", i)
    sid <- graph_add(s, function(id, ...) { n@id <- id; n })
    did <- graph_import(g, s, sid)
    expect_identical(graph_get(g, did)@path, paste0("p", i))
  }
  expect_identical(length(graph_ids(g)), 20L)
  # uids are distinct per graph and stable for the graph's life
  a <- graph_new(); b <- graph_new()
  expect_false(identical(garry:::.graph_uid(a), garry:::.graph_uid(b)))
  expect_identical(garry:::.graph_uid(a), a@nodes$.uid)
  # a graph without the field (deserialised from an older session) gets one
  rm(list = ".uid", envir = a@nodes)
  u <- garry:::.graph_uid(a)
  expect_true(nzchar(u))
  expect_identical(garry:::.graph_uid(a), u)
})

test_that("sources that read different values are not merged", {
  f <- fixture_gradient_f32()
  raw <- .fixture_values(60, 40)

  # same file and band, different band affine
  a <- lazy_source(f, scale = 0.5, offset = 0)
  b <- lazy_source(f)
  expect_equal(collect(a + b), 1.5 * raw, ignore_attr = TRUE)
  c2 <- lazy_source(f, scale = 2, offset = 1)
  expect_equal(collect(a + c2), 0.5 * raw + 2 * raw + 1, ignore_attr = TRUE)

  # same file on a coarser grid, different read-time resampler
  g <- lazy_source(f)@grid
  coarse <- grid_spec(
    crs = grid_crs(g),
    extent = grid_bbox(g),
    dims = as.integer(c(g@dims[["x"]], g@dims[["y"]]) / 2)
  )
  near <- lazy_source(f, grid = coarse, resampling = "near")
  avg <- lazy_source(f, grid = coarse, resampling = "average")
  both <- near - avg
  n_src <- sum(vapply(
    graph_ids(both@graph),
    function(i) S7::S7_inherits(graph_get(both@graph, i), SourceNode),
    logical(1)
  ))
  expect_identical(n_src, 2L)
  expect_equal(collect(both), collect(near) - collect(avg))
})
