# lazy_cog: the specialist multi-band COG read path via cptkirk. The cptkirk
# fetch needs a tiled COG, which we exercise end-to-end on a LOCAL tiled COG (no
# network). The VRT bridge and the dequant are also unit-tested cptkirk-free.

test_that("dequantize_aef matches the reference decode on plain numerics", {
  x <- c(-127, -100, -50, 0, 50, 100, 127)
  expect_equal(dequantize_aef(x), ((x / 127.5)^2) * sign(x), tolerance = 1e-6)
})

test_that(".raw_bsq_vrt_xml describes a raw BSQ buffer GDAL reads with the sentinel", {
  nx <- 4L; ny <- 3L; nd <- -128L
  b1 <- rep(-100L, nx * ny); b1[[1]] <- nd
  b2 <- rep(90L, nx * ny)
  dir <- withr::local_tempdir("ckvrt")
  bin <- file.path(dir, "buf.bin"); writeBin(c(b1, b2), bin, size = 1L)
  xml <- garry:::.raw_bsq_vrt_xml("buf.bin", nx, ny, "0, 10, 0, 30, 0, -10",
                                  gdalraster::srs_to_wkt("EPSG:3857"),
                                  "Int8", 2L, nodata = nd)
  vrt <- file.path(dir, "buf.vrt"); writeLines(xml, vrt)
  r <- methods::new(gdalraster::GDALRaster, vrt, TRUE)
  on.exit(r$close())
  expect_identical(r$getRasterCount(), 2L)
  expect_equal(r$getNoDataValue(1), -128)
  expect_equal(r$read(1, 0, 0, 4, 1, 4, 1), c(NA, -100, -100, -100))  # sentinel -> NA
  expect_equal(r$read(2, 0, 0, 4, 1, 4, 1), c(90, 90, 90, 90))
})

# A local tiled multi-band Int8 COG fixture (cptkirk requires a tiled TIFF).
.lc_cog <- function(dir, codes = c(-40L, 50L, 90L), nd = NULL) {
  f <- file.path(dir, "cog.tif")
  d <- gdalraster::create("GTiff", f, 512, 512, length(codes), "Int8",
                          return_obj = TRUE,
                          options = c("TILED=YES", "BLOCKXSIZE=256",
                                      "BLOCKYSIZE=256"))
  d$setGeoTransform(c(0, 10, 0, 5120, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  for (b in seq_along(codes)) {
    if (!is.null(nd)) d$setNoDataValue(b, nd)
    d$write(b, 0, 0, 512, 512, rep(codes[[b]], 512 * 512))
  }
  d$close()
  f
}

test_that("lazy_cog is lazy: construction records a CK: source, fetches nothing", {
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lclazy")
  f <- .lc_cog(dir)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(64L, 64L), dtype = "f32")
  p <- collect(lazy_cog(f, grid), plan_only = TRUE)        # no fetch
  paths <- vapply(graph_ids(p@graph), function(id) {
    n <- graph_get(p@graph, id)
    if (S7::S7_inherits(n, garry:::SourceNode)) n@path else ""
  }, "")
  expect_true(any(startsWith(paths, "CK:")))
})

test_that("lazy_cog reads a multi-band COG and fuses dequant (end to end)", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lc")
  f <- .lc_cog(dir)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(256L, 256L), dtype = "f32")
  ds <- lazy_cog(f, grid, names = c("e1", "e2", "e3"))
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_named(ds@bands, c("e1", "e2", "e3"))

  # decode is a pipeline map (not a reader arg); garry fuses it onto the read
  got <- collect(lazy_map(ds, fn = dequantize_aef, dtype = "f32"),
                 distributed = FALSE)
  ref <- function(x) ((x / 127.5)^2) * sign(x)
  expect_equal(dim(got), c(256L, 256L, 3L))
  expect_equal(unname(got[1, 1, 1]), ref(-40), tolerance = 1e-4)
  expect_equal(unname(got[1, 1, 2]), ref(50),  tolerance = 1e-4)
  expect_equal(unname(got[1, 1, 3]), ref(90),  tolerance = 1e-4)
})

test_that("lazy_cog carries the source sentinel to NaN before the decode", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lcnd")
  f <- .lc_cog(dir, codes = c(-128L, 90L), nd = -128L)     # band 1 is all sentinel
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(64L, 64L), dtype = "f32")
  got <- collect(lazy_map(lazy_cog(f, grid), fn = dequantize_aef, dtype = "f32"),
                 distributed = FALSE)
  expect_true(all(is.na(got[, , 1])))                      # sentinel band -> nodata
  expect_equal(unname(got[1, 1, 2]), (90 / 127.5)^2, tolerance = 1e-4)
})

test_that("lazy_cog band subset reads and names only the selected bands", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lcsub")
  f <- .lc_cog(dir, codes = c(-40L, 50L, 90L))
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(64L, 64L), dtype = "f32")
  got <- collect(lazy_cog(f, grid, bands = c(1L, 3L)), distributed = FALSE)
  expect_equal(dim(got), c(64L, 64L, 2L))
  expect_equal(unname(got[1, 1, 1]), -40)                  # band 1 raw code
  expect_equal(unname(got[1, 1, 2]),  90)                  # band 3 raw code
})

# A tiled single-band Int8 COG covering [x0, x0 + 2560) x [0, 5120), value `code`.
.lc_tile <- function(f, x0, code) {
  d <- gdalraster::create("GTiff", f, 256, 512, 1, "Int8", return_obj = TRUE,
                          options = c("TILED=YES", "BLOCKXSIZE=256",
                                      "BLOCKYSIZE=256"))
  d$setGeoTransform(c(x0, 10, 0, 5120, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$write(1, 0, 0, 256, 512, rep(code, 256 * 512))
  d$close()
  f
}

test_that("lazy_cog mosaics a vector of tiles in one fetch (B2)", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lcmos")
  left  <- .lc_tile(file.path(dir, "L.tif"), 0,    -40L)
  right <- .lc_tile(file.path(dir, "R.tif"), 2560,  90L)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(4L, 4L), dtype = "f32")
  got <- collect(lazy_cog(c(left, right), grid), distributed = FALSE)
  expect_equal(dim(got), c(4L, 4L))                        # one band -> 2D matrix
  expect_true(all(got[, 1:2] == -40))                      # left cols from tile L
  expect_true(all(got[, 3:4] ==  90))                      # right cols from tile R
})

test_that("lazy_cog reads under distributed daemons (shared /dev/shm staging, B3)", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  dir <- withr::local_tempdir("lcdist")
  f <- .lc_cog(dir)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(128L, 128L), dtype = "f32")
  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  got <- collect(lazy_map(lazy_cog(f, grid), fn = dequantize_aef, dtype = "f32"),
                 distributed = TRUE)
  ref <- function(x) ((x / 127.5)^2) * sign(x)
  expect_equal(dim(got), c(128L, 128L, 3L))
  expect_equal(unname(got[1, 1, 1]), ref(-40), tolerance = 1e-4)
  expect_equal(unname(got[64, 64, 3]), ref(90), tolerance = 1e-4)
})

# A tiled single-band COG with a nodata sentinel, for time-series fixtures. Real
# HLS/AEF assets always carry nodata, which the D8 promotion needs to read
# integer values as f32 (so temporal medians are exact, not integer-truncated).
.lc_scog <- function(f, code, nd = -32768L, dtype = "Int16") {
  d <- gdalraster::create("GTiff", f, 64, 64, 1, dtype, return_obj = TRUE,
                          options = c("TILED=YES", "BLOCKXSIZE=64",
                                      "BLOCKYSIZE=64"))
  d$setGeoTransform(c(0, 10, 0, 640, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$setNoDataValue(1, nd)
  d$write(1, 0, 0, 64, 64, rep(code, 64 * 64))
  d$close()
  f
}

test_that("lazy_cog (dataframe form) mirrors lazy_dataset: time-series median", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lcser")
  src <- data.frame(
    location = c(.lc_scog(file.path(dir, "a1.tif"), 10L),
                 .lc_scog(file.path(dir, "a2.tif"), 20L),
                 .lc_scog(file.path(dir, "a3.tif"), 30L),
                 .lc_scog(file.path(dir, "b1.tif"), 50L),
                 .lc_scog(file.path(dir, "b2.tif"), 70L),
                 .lc_scog(file.path(dir, "b3.tif"), 90L)),
    datetime = rep(c("2023-01-01", "2023-02-01", "2023-03-01"), 2),
    asset = rep(c("A", "B"), each = 3), stringsAsFactors = FALSE)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 640, 640),
                    dims = c(16L, 16L), dtype = "f32")
  ds <- lazy_cog(src, grid, assets = c("A", "B"), granularity = "month")
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_named(ds@bands, c("A", "B"))
  expect_equal(vapply(ds@bands, length, 1L), c(A = 3L, B = 3L))

  got <- collect(reduce_over(ds, "median", "t", nan_rm = TRUE), distributed = FALSE)
  expect_equal(dim(got), c(16L, 16L, 2L))
  expect_equal(unname(got[1, 1, 1]), 20)                   # median(10, 20, 30)
  expect_equal(unname(got[1, 1, 2]), 70)                   # median(50, 70, 90)
})

# A half-width tiled Int16 COG (nodata set), covering x in [x0, x0+320) over the
# 640x640 test grid -- for building a 2-tile mosaic source set.
.lc_half <- function(f, x0, code, nd = -32768L) {
  d <- gdalraster::create("GTiff", f, 32, 64, 1, "Int16", return_obj = TRUE,
                          options = c("TILED=YES", "BLOCKXSIZE=32",
                                      "BLOCKYSIZE=64"))
  d$setGeoTransform(c(x0, 10, 0, 640, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$setNoDataValue(1, nd)
  d$write(1, 0, 0, 32, 64, rep(code, 32 * 64))
  d$close()
  f
}

test_that("lazy_cog (dataframe form) batches a mosaic slice through one pool", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lcbatchmos")
  # asset A slice has TWO tiles (left 20 / right 30 -> mosaic); asset B one tile.
  # Two source sets share a signature -> one ck_batch pool; A's tiles -> buildVRT.
  src <- data.frame(
    location = c(.lc_half(file.path(dir, "aL.tif"), 0,   20L),
                 .lc_half(file.path(dir, "aR.tif"), 320, 30L),
                 .lc_scog(file.path(dir, "b.tif"),  50L)),
    datetime = "2023-01-01", asset = c("A", "A", "B"), stringsAsFactors = FALSE)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 640, 640),
                    dims = c(16L, 16L), dtype = "f32")
  got <- collect(reduce_over(lazy_cog(src, grid, assets = c("A", "B")),
                             "median", "t", nan_rm = TRUE), distributed = FALSE)
  expect_equal(dim(got), c(16L, 16L, 2L))
  expect_true(all(got[, 1:8, 1] == 20))                    # A left half from tile aL
  expect_true(all(got[, 9:16, 1] == 30))                   # A right half from tile aR
  expect_true(all(got[, , 2] == 50))                       # B single tile
})

test_that("lazy_cog (dataframe form) carries a mask asset for mask()", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  dir <- withr::local_tempdir("lcmask")
  src <- data.frame(
    location = c(.lc_scog(file.path(dir, "v.tif"), 100L),
                 .lc_scog(file.path(dir, "q.tif"), 1L, nd = 255L, dtype = "Byte")),
    datetime = "2023-01-01", asset = c("V", "Q"), stringsAsFactors = FALSE)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 640, 640),
                    dims = c(16L, 16L), dtype = "f32")
  masked <- mask(lazy_cog(src, grid, assets = "V", mask_asset = "Q"),
                 from = "Q", where = qa_bits(0L)) |>
    reduce_over("median", "t", nan_rm = TRUE)
  expect_true(all(is.na(collect(masked, distributed = FALSE))))  # Q bit0 set -> masked
})
