test_that("GridSpec validates shape", {
  expect_error(
    GridSpec(crs = "EPSG:4326", transform = 1:5,
             extent = c(0, 0, 1, 1), dims = c(10L, 10L), dtype = "f32"),
    "transform"
  )
  expect_error(
    GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, -1),
             extent = c(1, 0, 0, 1), dims = c(10L, 10L), dtype = "f32"),
    "xmin"
  )
})

test_that("grid_spec derives dims from res and snaps the extent", {
  # exact fit: 15360 / 30 = 512, extent unchanged
  g <- grid_spec("EPSG:32736", extent = c(510000, 8540000, 525360, 8555360),
                 res = 30)
  expect_equal(unname(g@dims), c(512L, 512L))
  expect_equal(unname(res(g)), c(30, 30))
  expect_equal(g@extent, c(510000, 8540000, 525360, 8555360))

  # non-exact: 1000 / 30 = 33.3 -> 33 whole pixels, extent snapped to the
  # top-left anchor (990 x 990 wide, ymin lifted, xmax pulled in)
  g2 <- grid_spec("EPSG:3857", extent = c(0, 0, 1000, 1000), res = 30)
  expect_equal(unname(g2@dims), c(33L, 33L))
  expect_equal(unname(res(g2)), c(30, 30))
  expect_equal(g2@extent, c(0, 10, 990, 1000))

  # dims and res are mutually exclusive; exactly one is required
  expect_error(grid_spec("EPSG:3857", c(0, 0, 1, 1)), "exactly one")
  expect_error(grid_spec("EPSG:3857", c(0, 0, 1, 1),
                         dims = c(2L, 2L), res = 30), "exactly one")
  expect_error(grid_spec("EPSG:3857", c(0, 0, 10, 10), res = 100),
               "coarser")
})

test_that("grid_equal detects geometry-only differences", {
  g1 <- GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, -1),
                 extent = c(0, -10, 10, 0), dims = c(10L, 10L), dtype = "f32")
  g2 <- GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, -1),
                 extent = c(0, -10, 10, 0), dims = c(10L, 10L), dtype = "f64")
  expect_true(grid_equal(g1, g2))   # dtype differs, geometry same
})

test_that("chunk_iter covers the grid without gaps", {
  g  <- GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, -1),
                 extent = c(0, -100, 100, 0), dims = c(100L, 100L), dtype = "f32")
  cg <- ChunkGrid(grid = g, chunk_dim = c(32L, 32L),
                  block_dim = c(32L, 32L), halo = 0L)
  it <- chunk_iter(cg)
  expect_equal(sum(it$x_size * it$y_size), 100L * 100L)
})

test_that("halo padding clips at edges", {
  g  <- GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, -1),
                 extent = c(0, -100, 100, 0), dims = c(100L, 100L), dtype = "f32")
  cg <- ChunkGrid(grid = g, chunk_dim = c(32L, 32L),
                  block_dim = c(32L, 32L), halo = 2L)
  w  <- chunk_window_with_halo(cg, x_off = 0L, y_off = 0L,
                               x_size = 32L, y_size = 32L)
  expect_equal(w$pad_left, 0L)
  expect_equal(w$pad_top,  0L)
  expect_equal(w$pad_right,  2L)
  expect_equal(w$pad_bottom, 2L)
})
