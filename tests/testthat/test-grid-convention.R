# Decision D1 lock: extent order is (xmin, ymin, xmax, ymax) everywhere in
# garry; vaster's (xmin, xmax, ymin, ymax) exists only behind
# as_vaster_extent(). If this file fails, someone flipped a convention.

test_that("GridSpec extent order is (xmin, ymin, xmax, ymax)", {
  # 30 m UTM-style grid: origin (500000, 4600000), 100 x 80 pixels.
  g <- GridSpec(
    crs       = "EPSG:32632",
    transform = c(500000, 30, 0, 4600000, 0, -30),
    extent    = c(500000, 4600000 - 80 * 30, 500000 + 100 * 30, 4600000),
    dims       = c(100L, 80L),
    dtype     = "f32"
  )
  expect_identical(xmin(g), 500000)
  expect_identical(ymin(g), 4600000 - 2400)
  expect_identical(xmax(g), 503000)
  expect_identical(ymax(g), 4600000)
  expect_identical(res(g), c(30, 30))
})

test_that("incoherent extent/transform/dim is rejected", {
  expect_error(
    GridSpec(crs = "EPSG:32632",
             transform = c(500000, 30, 0, 4600000, 0, -30),
             extent    = c(500000, 4597600, 503000 + 30, 4600000),  # xmax off by 1px
             dims       = c(100L, 80L),
             dtype     = "f32"),
    "does not agree"
  )
})

test_that("rotated and south-up grids are rejected", {
  expect_error(
    GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0.1, 10, 0, -1),
             extent = c(0, 0, 10, 10), dims = c(10L, 10L), dtype = "f32"),
    "rotated"
  )
  expect_error(
    GridSpec(crs = "EPSG:4326", transform = c(0, 1, 0, 0, 0, 1),
             extent = c(0, 0, 10, 10), dims = c(10L, 10L), dtype = "f32"),
    "north-up"
  )
})

test_that("as_vaster_extent reorders to (xmin, xmax, ymin, ymax)", {
  g <- grid_spec("EPSG:4326", extent = c(0, -10, 10, 0), dims = c(10L, 10L))
  expect_identical(as_vaster_extent(g), c(0, 10, -10, 0))
  expect_identical(as_vaster_extent(c(1, 2, 3, 4)), c(1, 3, 2, 4))
})

test_that("vaster round-trip agrees with garry's transform math", {
  g <- grid_spec("EPSG:4326", extent = c(0, -10, 10, 0), dims = c(10L, 10L))
  ve <- as_vaster_extent(g)
  d  <- unname(g@dims[1:2])

  # Centre of the top-left pixel: vaster cell 1 (row-major from top-left).
  expect_equal(vaster::cell_from_xy(d, ve, cbind(0.5, -0.5)), 1L)
  # Centre of pixel (col 3, row 2) -> cell (2-1)*10 + 3.
  expect_equal(vaster::cell_from_xy(d, ve, cbind(2.5, -1.5)), 13L)
  # xy_from_cell inverts.
  expect_equal(as.numeric(vaster::xy_from_cell(d, ve, 13L)), c(2.5, -1.5))
  # vaster's geotransform from the reordered extent equals ours.
  expect_equal(as.numeric(vaster::extent_dim_to_gt(ve, d)), g@transform)
})

test_that("grid_spec derives a coherent transform", {
  g <- grid_spec("EPSG:3857", extent = c(-100, -200, 300, 200),
                 dims = c(40L, 40L), dtype = "f64")
  expect_identical(g@transform, c(-100, 10, 0, 200, 0, -10))
  expect_identical(g@dtype, "f64")
})
