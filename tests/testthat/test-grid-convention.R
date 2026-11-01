# Decision D1 lock: extent order is (xmin, ymin, xmax, ymax) everywhere in
# garry. If this file fails, someone flipped a convention.

test_that("GridSpec extent order is (xmin, ymin, xmax, ymax)", {
  # 30 m UTM-style grid: origin (500000, 4600000), 100 x 80 pixels.
  g <- GridSpec(
    crs       = "EPSG:32632",
    transform = c(500000, 30, 0, 4600000, 0, -30),
    extent    = c(500000, 4600000 - 80 * 30, 500000 + 100 * 30, 4600000),
    dims       = c(100L, 80L),
    dtype     = "f32"
  )
  expect_identical(grid_bbox(g)[["xmin"]], 500000)
  expect_identical(grid_bbox(g)[["ymin"]], 4600000 - 2400)
  expect_identical(grid_bbox(g)[["xmax"]], 503000)
  expect_identical(grid_bbox(g)[["ymax"]], 4600000)
  expect_identical(unname(grid_res(g)), c(30, 30))
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

test_that("a rotated file's error names the file and the way out", {
  f <- withr::local_tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", f, 8L, 8L, 1L, "Float32", return_obj = TRUE)
  ds$setGeoTransform(c(0, 1, 0.1, 10, 0, -1))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:4326"))
  ds$close()
  err <- expect_error(gdal_grid_spec(f), "rotated")
  expect_match(conditionMessage(err), basename(f), fixed = TRUE)
  expect_match(conditionMessage(err), "gdalwarp", fixed = TRUE)
})

test_that("grid_spec derives a coherent transform", {
  g <- grid_spec("EPSG:3857", extent = c(-100, -200, 300, 200),
                 dims = c(40L, 40L), dtype = "f64")
  expect_identical(g@transform, c(-100, 10, 0, 200, 0, -10))
  expect_identical(g@dtype, "f64")

  # an extent reaching down from y = 0: the top edge stays the origin
  g <- grid_spec("EPSG:4326", extent = c(0, -10, 10, 0), dims = c(10L, 10L))
  expect_identical(g@transform, c(0, 1, 0, 0, 0, -1))
})
