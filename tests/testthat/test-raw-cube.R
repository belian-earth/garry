# Raw-BSQ cube format (.bin + sibling VRTRawRasterBand .vrt): garry's
# intermediate format whose reads bypass GDAL's tile machinery (~9x on
# a 73-band cube, measured 2026-08-02: the tile walk costs ~2.2 s per
# 482 MB window REGARDLESS of compression; raw reads 0.24 s). Gates:
# the fast path is byte-identical to the GDAL path on the same VRT
# across bands/windows/out-modes/nodata/f64; .vrt sinks roundtrip
# (single-threaded and streamed through the writer daemon);
# stage_raw_cube() converts faithfully.

.rc_fixture <- function(dir, nb = 5L, dtype = "Float32", nodata = NULL) {
  nx <- 60L; ny <- 40L
  f <- file.path(dir, "src.tif")
  d <- gdalraster::create("GTiff", f, nx, ny, nb, dtype, return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 400, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  set.seed(9)
  for (b in seq_len(nb)) {
    v <- round(runif(nx * ny, -5, 100), 3)
    if (!is.null(nodata)) v[sample(nx * ny, 50)] <- nodata
    d$write(b, 0, 0, nx, ny, v)
    if (!is.null(nodata)) d$setNoDataValue(b, nodata)
  }
  d$close()
  f
}

test_that("fast path == GDAL path on the same raw cube, all shapes", {
  dir <- withr::local_tempdir("rc")
  src <- .rc_fixture(dir, nb = 5L)
  vrt <- file.path(dir, "cube.vrt")
  stage_raw_cube(src, vrt)
  expect_false(is.null(garry:::.raw_vrt_info(vrt)))
  # a differently-named copy dodges the .vrt extension gate, forcing the
  # GDAL path over the SAME bytes
  gdal_copy <- file.path(dir, "cube.gdalvrt")
  file.copy(vrt, gdal_copy)
  xml <- readLines(gdal_copy)
  writeLines(xml, gdal_copy)   # sibling reference still resolves
  expect_null(garry:::.raw_vrt_info(gdal_copy))

  wins <- list(c(0L, 0L, 60L, 40L),      # full raster
               c(0L, 8L, 60L, 16L),      # full-width slab
               c(7L, 5L, 21L, 13L))      # interior window
  for (w in wins) for (bset in list(1L, 3L, c(2L, 4L), 1:5)) {
    a <- gdal_read_window(vrt, bset, w[1], w[2], w[3], w[4])
    b <- gdal_read_window(gdal_copy, bset, w[1], w[2], w[3], w[4])
    expect_identical(a, b)
    ar <- gdal_read_window(vrt, bset, w[1], w[2], w[3], w[4],
                           out = "raw_f32")
    br <- gdal_read_window(gdal_copy, bset, w[1], w[2], w[3], w[4],
                           out = "raw_f32")
    expect_identical(ar, br)
  }
})

test_that("nodata sentinel mapping matches through the fast path", {
  dir <- withr::local_tempdir("rcn")
  src <- .rc_fixture(dir, nb = 3L, nodata = -9999)
  vrt <- file.path(dir, "cube.vrt")
  stage_raw_cube(src, vrt)
  gdal_copy <- file.path(dir, "cube.gdalvrt")
  file.copy(vrt, gdal_copy)
  a <- gdal_read_window(vrt, 1:3, 3L, 2L, 30L, 20L, nodata = -9999)
  b <- gdal_read_window(gdal_copy, 1:3, 3L, 2L, 30L, 20L, nodata = -9999)
  expect_identical(a, b)
  expect_true(any(is.nan(a)))
})

test_that("f64 cubes read identically through the fast path", {
  dir <- withr::local_tempdir("rc64")
  src <- .rc_fixture(dir, nb = 2L, dtype = "Float64")
  vrt <- file.path(dir, "cube.vrt")
  stage_raw_cube(src, vrt)
  info <- garry:::.raw_vrt_info(vrt)
  expect_identical(info$dtype, "f64")
  gdal_copy <- file.path(dir, "cube.gdalvrt")
  file.copy(vrt, gdal_copy)
  expect_identical(gdal_read_window(vrt, 1:2, 0L, 0L, 60L, 40L),
                   gdal_read_window(gdal_copy, 1:2, 0L, 0L, 60L, 40L))
})

test_that("collect(path = '*.vrt') writes a raw cube, single-threaded", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  vrt <- file.path(withr::local_tempdir("rcw"), "out.vrt")
  collect(lazy_source(f) + 1, path = vrt)
  expect_true(file.exists(sub("\\.vrt$", ".bin", vrt)))
  want <- collect(lazy_source(f) + 1)
  got <- gdal_read_window(vrt, 1L, 0L, 0L, 60L, 40L)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("streamed distributed writes land in a raw cube via the writer", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  garry_daemons(2, 1, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)
  withr::local_options(garry.chunk_target_px = 600)
  f <- fixture_gradient_f32()
  vrt <- file.path(withr::local_tempdir("rcd"), "out.vrt")
  collect(lazy_source(f) + 1, path = vrt, distributed = TRUE)
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  got <- gdal_read_window(vrt, 1L, 0L, 0L, 60L, 40L)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a raw cube feeds lazy_source like any raster", {
  skip_if_not_installed("anvl")
  dir <- withr::local_tempdir("rcs")
  src <- .rc_fixture(dir, nb = 1L)
  vrt <- file.path(dir, "cube.vrt")
  stage_raw_cube(src, vrt)
  want <- collect(lazy_source(src) + 1)
  got <- collect(lazy_source(vrt) + 1)
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = "gis")
})
