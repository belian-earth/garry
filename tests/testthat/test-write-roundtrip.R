# Phase 4b gate: write sinks. Roundtrips are bit-exact; NaN demotes to
# the sentinel on write (D8 reversed); integer output with NaN and no
# sentinel errors.

skip_if_not_installed("anvl")

test_that("f32 pipeline writes and reads back bit-exactly", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expr <- a * 2 + 1

  in_mem <- collect(expr)
  outfile <- tempfile(fileext = ".tif")
  old <- options(garry.chunk_target_px = 300)   # chunked writes
  on.exit(options(old))
  collect(expr, path = outfile)

  back <- gdal_read_window(outfile, 1L, 0L, 0L, 60L, 40L)
  expect_equal(back, in_mem, tolerance = 0, ignore_attr = "gis")

  meta <- gdal_grid_spec(outfile)
  src <- gdal_grid_spec(f)$grid
  expect_true(grid_equal(meta$grid, src))
  expect_identical(meta$grid@dtype, "f32")
})

test_that("NaN demotes to the sentinel and survives a roundtrip", {
  f <- fixture_i16_nodata()
  a <- lazy_source(f)                      # f32 with NaN
  outfile <- tempfile(fileext = ".tif")
  collect(a * 1, path = outfile, nodata = -9999)

  meta <- gdal_grid_spec(outfile)
  expect_identical(meta$nodata, -9999)

  # gdalraster masks file-nodata on read, so the 26 sentinel cells the
  # writer demoted come back as NaN even without explicit promotion.
  raw <- gdal_read_window(outfile, 1L, 0L, 0L, 70L, 50L)
  expect_identical(sum(is.nan(raw)), 26L)

  back <- gdal_read_window(outfile, 1L, 0L, 0L, 70L, 50L,
                           nodata = meta$nodata)
  want <- gdal_read_window(f, 1L, 0L, 0L, 70L, 50L,
                           nodata = gdal_grid_spec(f)$nodata)
  expect_identical(is.nan(back), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(back[ok], want[ok], tolerance = 0)
})

test_that("pure-source write copies the raster (i16 in, i16 out)", {
  # A no-nodata integer source keeps its dtype end to end.
  f <- file.path(tempdir(), "garry-fixture-i16-plain.tif")
  if (!file.exists(f)) {
    ds <- gdalraster::create("GTiff", f, 20, 15, 1, "Int16",
                             return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 150, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 20, 15,
             as.numeric(t(outer(1:15, 1:20, function(r, c2) r * 100 + c2))))
    ds$close()
  }
  a <- lazy_source(f)
  expect_identical(a@grid@dtype, "i16")
  outfile <- tempfile(fileext = ".tif")
  collect(a, path = outfile)

  expect_identical(gdal_grid_spec(outfile)$grid@dtype, "i16")
  expect_identical(gdal_read_window(outfile, 1L, 0L, 0L, 20L, 15L),
                   gdal_read_window(f, 1L, 0L, 0L, 20L, 15L))
})

test_that("integer output with NaN and no sentinel errors; scalars refuse", {
  f <- fixture_i16_nodata()
  a <- lazy_source(f)
  expect_error(
    collect(reduce_over(a, "mean", c("x", "y")),
            path = tempfile(fileext = ".tif")),
    class = "garry_plan_error")
})
