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
  ds <- lazy_cog(f, grid, dequant = dequantize_aef, names = c("e1", "e2", "e3"))
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_named(ds@bands, c("e1", "e2", "e3"))

  got <- collect(ds, distributed = FALSE)
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
  got <- collect(lazy_cog(f, grid, dequant = dequantize_aef), distributed = FALSE)
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
  got <- collect(lazy_cog(f, grid, dequant = dequantize_aef), distributed = TRUE)
  ref <- function(x) ((x / 127.5)^2) * sign(x)
  expect_equal(dim(got), c(128L, 128L, 3L))
  expect_equal(unname(got[1, 1, 1]), ref(-40), tolerance = 1e-4)
  expect_equal(unname(got[64, 64, 3]), ref(90), tolerance = 1e-4)
})
