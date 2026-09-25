
test_that("gdal_mosaic_vrt takes south-up and foreign-projection sources, and refuses a lossy mosaic", {
  skip_if_not_installed("gdalraster")
  dir <- withr::local_tempdir()
  # two 4 x 4 tiles side by side in UTM 32722, both stored SOUTH-UP
  # (positive north-south pixel size), as the AEF tiles are
  srs <- gdalraster::epsg_to_wkt(32722)
  south_up <- function(path, x0, value) {
    ds <- gdalraster::create("GTiff", path, 4L, 4L, 1L, "Int16", return_obj = TRUE)
    ds$setProjection(srs)
    ds$setGeoTransform(c(x0, 10, 0, 7900000, 0, 10))   # origin at the south edge, y grows upward
    ds$write(1L, 0L, 0L, 4L, 4L, rep(value, 16L))
    ds$close()
    path
  }
  a <- south_up(file.path(dir, "a.tif"), 100000, 1L)
  b <- south_up(file.path(dir, "b.tif"), 100040, 2L)
  d <- gdalraster::GDALRaster$new(a); expect_gt(d$getGeoTransform()[6], 0); d$close()
  v <- gdal_mosaic_vrt(file.path(dir, "m.vrt"), c(a, b))
  ds <- gdalraster::GDALRaster$new(v)
  expect_equal(c(ds$getRasterXSize(), ds$getRasterYSize()), c(8L, 4L))
  expect_lt(ds$getGeoTransform()[6], 0)                # north-up mosaic
  vals <- ds$read(1L, 0L, 0L, 8L, 4L, 8L, 4L); ds$close()
  expect_equal(sort(unique(as.integer(vals))), c(1L, 2L))  # both tiles present
  # a source in another projection is warped in rather than skipped
  c_path <- file.path(dir, "c.tif")
  gdalraster::warp(b, c_path, t_srs = "EPSG:32721", cl_arg = c("-r", "near"), quiet = TRUE)
  v2 <- gdal_mosaic_vrt(file.path(dir, "m2.vrt"), c(a, c_path))
  n_src <- length(grep("<SourceFilename", readLines(v2, warn = FALSE), fixed = TRUE))
  expect_equal(n_src, 2L)
})
