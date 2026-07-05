# Decision D2 lock: CRS is canonicalised at construction; equal reference
# systems compare equal regardless of how the user spelled them.

test_that("EPSG, WKT, and proj4 spellings construct equal grids", {
  ext <- c(0, -10, 10, 0); d <- c(10L, 10L)
  g_epsg <- grid_spec("EPSG:4326", ext, d)
  g_wkt  <- grid_spec(gdalraster::srs_to_wkt("EPSG:4326"), ext, d)
  g_proj <- grid_spec("+proj=longlat +datum=WGS84 +no_defs", ext, d)

  expect_true(grid_equal(g_epsg, g_wkt))
  expect_true(grid_equal(g_epsg, g_proj))
  # Canonicalisation makes the fast path (string identity) hit.
  expect_identical(g_epsg@crs, g_wkt@crs)
})

test_that("different reference systems are unequal", {
  ext <- c(0, -10, 10, 0); d <- c(10L, 10L)
  g1 <- grid_spec("EPSG:4326", ext, d)
  g2 <- grid_spec("EPSG:3857", ext, d)
  expect_false(grid_equal(g1, g2))
  expect_false(crs_equal(g1@crs, g2@crs))
})

test_that("garbage CRS errors at construction", {
  expect_error(grid_spec("not-a-crs", c(0, 0, 1, 1), c(2L, 2L)))
})

test_that("geometry differences are caught with equal CRS", {
  g1 <- grid_spec("EPSG:4326", c(0, -10, 10, 0), c(10L, 10L))
  g2 <- grid_spec("EPSG:4326", c(0, -10, 10, 0), c(20L, 20L))
  g3 <- grid_spec("EPSG:4326", c(0, -20, 10, 0), c(10L, 20L))
  expect_false(grid_equal(g1, g2))
  expect_false(grid_equal(g1, g3))
})
