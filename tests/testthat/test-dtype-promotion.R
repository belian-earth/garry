# The dtype a plan declares is the dtype its kernels compute, so written
# files hold what collect() returns. Integer sources are the risky case:
# float arithmetic and wide sums leave the integer range.

.int_source <- function(dtype = "UInt16", vals = as.numeric(1:600)) {
  f <- withr::local_tempfile(fileext = ".tif", .local_envir = parent.frame())
  ds <- gdalraster::create("GTiff", f, 30, 20, 1, dtype, return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 200, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, 30, 20, vals)
  ds$close()
  f
}

test_that("a double scalar makes an integer raster f32; an integer keeps it", {
  x <- lazy_source(.int_source())
  expect_identical(x@grid@dtype, "u16")
  expect_identical((x * 0.5)@grid@dtype, "f32")
  expect_identical((x - 100)@grid@dtype, "f32")
  expect_identical((x * 2L)@grid@dtype, "u16")
  expect_identical(sqrt(x)@grid@dtype, "f32")
})

test_that("write_tif of float arithmetic on an integer source equals collect", {
  x <- lazy_source(.int_source())
  y <- x * 0.5 - 100
  path <- withr::local_tempfile(fileext = ".tif")
  write_tif(y, path)
  got <- gdal_read_window(path, 1L, 0L, 0L, 30L, 20L)
  expect_equal(got, collect(y), ignore_attr = TRUE, tolerance = 1e-6)
})

test_that("an 8-bit sum over many slices does not wrap", {
  x <- lazy_source(.int_source("Byte", rep(200, 600)))
  s <- reduce_over(lazy_stack(rep(list(x), 3)), "sum", "t")
  expect_identical(s@grid@dtype, "i32")
  expect_true(all(collect(s) == 600))
})

test_that("Math on an integer dataset declares f32 per band", {
  x <- lazy_source(.int_source())
  ds <- as_dataset(list(a = x, b = x * 0.5))
  r <- sqrt(ds)
  expect_identical(r$a@grid@dtype, "f32")
  expect_identical(r$b@grid@dtype, "f32")
  expect_equal(collect(r$a), sqrt(collect(x)), tolerance = 1e-6, ignore_attr = TRUE)
})
