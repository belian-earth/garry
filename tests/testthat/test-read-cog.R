# The multi-band COG read engine: the cptkirk fetch (.ck_warp_local) needs a
# remote source + cptkirk, so it is exercised live elsewhere. Here we test the
# garry-side wrapping (.cog_to_dataset) and the fused AEF dequant map, which are
# network- and cptkirk-free.

test_that("dequantize_aef matches the reference decode on plain numerics", {
  x <- c(-127, -100, -50, 0, 50, 100, 127)
  expect_equal(dequantize_aef(x), ((x / 127.5)^2) * sign(x), tolerance = 1e-6)
})

test_that(".cog_to_dataset wraps a local multi-band raster and fuses dequant", {
  skip_if_not_installed("anvl")
  # 3-band Int8 raster with a distinct code per band.
  f <- tempfile(fileext = ".tif")
  d <- gdalraster::create("GTiff", f, 4, 3, 3, "Int8", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 30, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  codes <- c(-100L, 50L, 127L)
  for (b in 1:3) d$write(b, 0, 0, 4, 3, rep(codes[[b]], 12))
  d$close()
  grid <- gdal_grid_spec(f)$grid

  ds <- garry:::.cog_to_dataset(f, grid, bands = 1:3, dequant = dequantize_aef,
                                names = c("e1", "e2", "e3"))
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_named(ds@bands, c("e1", "e2", "e3"))

  got <- collect(ds)                         # (y, x, 3)
  expect_equal(dim(got), c(3L, 4L, 3L))
  ref <- function(x) ((x / 127.5)^2) * sign(x)
  for (b in 1:3)
    expect_equal(unname(got[1, 1, b]), ref(codes[[b]]), tolerance = 1e-4)
})

test_that(".raw_bsq_vrt wraps a raw BSQ buffer; source sentinel masks to NaN", {
  skip_if_not_installed("anvl")
  # A 4x3 grid; the user's analysis grid is f32, the source buffer is Int8, so
  # .cog_to_dataset must read at the native i8 dtype for the D8 sentinel->NaN
  # promotion to fire (else -128 would decode instead of masking).
  f <- tempfile(fileext = ".tif")
  d <- gdalraster::create("GTiff", f, 4, 3, 1, "Int8", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 30, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$close()
  grid <- garry:::.grid_retype(gdal_grid_spec(f)$grid, "f32")

  nx <- 4L; ny <- 3L; nd <- -128L
  b1 <- rep(-100L, nx * ny); b1[[1]] <- nd     # (row0, col0) is the sentinel
  b2 <- rep(90L, nx * ny)
  bin <- tempfile(fileext = ".bin")
  writeBin(c(b1, b2), bin, size = 1L)          # BSQ: band 1 plane then band 2
  vrt <- garry:::.raw_bsq_vrt(bin, grid, "Int8", 2L, nodata = nd)

  ds <- garry:::.cog_to_dataset(vrt, grid, bands = 1:2, dequant = dequantize_aef,
                                names = c("e1", "e2"), nodata = nd)
  got <- collect(ds)
  ref <- function(x) ((x / 127.5)^2) * sign(x)
  expect_true(is.na(got[1, 1, 1]))                        # sentinel -> nodata
  expect_equal(unname(got[1, 2, 1]), ref(-100), tolerance = 1e-4)
  expect_equal(unname(got[1, 1, 2]), ref(90),  tolerance = 1e-4)
})

test_that(".cog_to_dataset without dequant returns the raw codes", {
  skip_if_not_installed("anvl")
  f <- tempfile(fileext = ".tif")
  d <- gdalraster::create("GTiff", f, 4, 3, 2, "Int8", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 30, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$write(1, 0, 0, 4, 3, rep(-40L, 12)); d$write(2, 0, 0, 4, 3, rep(90L, 12))
  d$close()
  grid <- gdal_grid_spec(f)$grid
  got <- collect(garry:::.cog_to_dataset(f, grid, bands = 1:2))
  expect_equal(unname(got[1, 1, 1]), -40, tolerance = 1e-4)
  expect_equal(unname(got[1, 1, 2]),  90, tolerance = 1e-4)
})
