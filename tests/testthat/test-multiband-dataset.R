# The file form of lazy_dataset(): multi-band rasters read band-by-band over
# the reader pool (design/gdal-multiband-fanout.md), exercised end to end on
# LOCAL tiled COGs (no network). The raw-VRT bridge and the quantiser decodes
# are unit-tested alongside (they shipped with the same read path).

test_that("dequantize_aef matches the reference decode on plain numerics", {
  x <- c(-127, -100, -50, 0, 50, 100, 127)
  expect_equal(dequantize_aef(x), ((x / 127.5)^2) * sign(x), tolerance = 1e-6)
})

test_that("dequantize_esd matches the reference FSQ decode over the full code range", {
  levels <- c(8L, 8L, 8L, 5L, 5L, 5L)
  basis <- cumprod(c(1, levels[-length(levels)]))
  x <- as.numeric(0:(prod(levels) - 1L))            # every ESD code
  for (j in seq_along(levels)) {
    half <- levels[[j]] %/% 2
    ref <- (((x %/% basis[[j]]) %% levels[[j]]) - half) / half
    expect_equal(dequantize_esd(x, j), ref)
  }
  # non-default levels: any FSQ product decodes by passing its own vector
  expect_equal(dequantize_esd(as.numeric(0:11), 2L, levels = c(3L, 4L)),
               (((0:11) %/% 3) %% 4 - 2) / 2)
  expect_true(is.nan(dequantize_esd(NaN, 1L)))       # nodata propagates (D8)
  expect_error(dequantize_esd(x, 7L), "level")
  expect_error(dequantize_esd(x, 0L), "level")
})

test_that("dequantize_esd decodes identically through a traced read", {
  codes <- matrix(rep_len(c(0L, 1L, 4093L, 31999L, 63999L), 40L * 60L), 40L, 60L)
  dir <- withr::local_tempdir("esd")
  f <- file.path(dir, "esd.tif")
  d <- gdalraster::create("GTiff", f, 60, 40, 1, "UInt16", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 400, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$write(1, 0, 0, 60, 40, as.integer(t(codes)))
  d$close()
  for (j in c(1L, 4L, 6L)) {
    got <- collect(lazy_map(lazy_source(f),
                            fn = function(x) dequantize_esd(x, j),
                            dtype = "f32"),
                   distributed = FALSE)
    expect_equal(unclass(got), dequantize_esd(codes, j),
                 tolerance = 1e-6, ignore_attr = TRUE)
  }
})

test_that(".raw_bsq_vrt_xml describes a raw BSQ buffer GDAL reads with the sentinel", {
  nx <- 4L; ny <- 3L; nd <- -128L
  b1 <- rep(-100L, nx * ny); b1[[1]] <- nd
  b2 <- rep(90L, nx * ny)
  dir <- withr::local_tempdir("rawvrt")
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

# A local tiled multi-band Int8 COG fixture, optionally with band
# descriptions and a nodata sentinel (the AEF tile shape in miniature).
.mb_cog <- function(dir, codes = c(-40L, 50L, 90L), nd = NULL, desc = NULL) {
  f <- file.path(dir, "cog.tif")
  d <- gdalraster::create("GTiff", f, 512, 512, length(codes), "Int8",
                          return_obj = TRUE,
                          options = c("TILED=YES", "BLOCKXSIZE=256",
                                      "BLOCKYSIZE=256"))
  d$setGeoTransform(c(0, 10, 0, 5120, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  for (b in seq_along(codes)) {
    if (!is.null(nd)) d$setNoDataValue(b, nd)
    if (!is.null(desc)) d$setDescription(b, desc[[b]])
    d$write(b, 0, 0, 512, 512, rep(codes[[b]], 512 * 512))
  }
  d$close()
  f
}

test_that("lazy_dataset(path) builds one band per file band, reads nothing", {
  dir <- withr::local_tempdir("mblazy")
  f <- .mb_cog(dir, nd = -128L)
  ds <- lazy_dataset(f)                                    # native grid
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_named(ds@bands, c("b1", "b2", "b3"))
  # per-band sources over the ORIGINAL path: no staging, no rewrite
  p <- collect(ds, plan_only = TRUE)
  src_paths <- unique(vapply(graph_ids(p@graph), function(id) {
    n <- graph_get(p@graph, id)
    if (S7::S7_inherits(n, garry:::SourceNode)) n@path else ""
  }, ""))
  expect_identical(setdiff(src_paths, ""), f)
  # native grid, f32 (integer + sentinel promotes, D8)
  g0 <- ds@bands[[1L]][[1L]]@grid
  expect_equal(unname(g0@dims), c(512L, 512L))
  expect_identical(g0@dtype, "f32")
})

test_that("lazy_dataset(path) names bands from file descriptions", {
  dir <- withr::local_tempdir("mbdesc")
  f <- .mb_cog(dir, desc = c("e1", "e2", "e3"))
  ds <- lazy_dataset(f)
  expect_named(ds@bands, c("e1", "e2", "e3"))
  # selection by name (assets), order as requested
  ds2 <- lazy_dataset(f, assets = c("e3", "e1"))
  expect_named(ds2@bands, c("e3", "e1"))
  expect_error(lazy_dataset(f, assets = "nope"), "not found")
  expect_error(lazy_dataset(f, assets = "e1", bands = 1L), "not both")
})

test_that("lazy_dataset(path) reads a multi-band COG and fuses dequant (end to end)", {
  dir <- withr::local_tempdir("mb")
  f <- .mb_cog(dir, desc = c("e1", "e2", "e3"))
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(256L, 256L), dtype = "f32")
  ds <- lazy_dataset(f, grid)
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

test_that("lazy_dataset(path) carries the source sentinel to NaN before the decode", {
  dir <- withr::local_tempdir("mbnd")
  f <- .mb_cog(dir, codes = c(-128L, 90L), nd = -128L)     # band 1 is all sentinel
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(64L, 64L), dtype = "f32")
  got <- collect(lazy_map(lazy_dataset(f, grid), fn = dequantize_aef,
                          dtype = "f32"),
                 distributed = FALSE)
  expect_true(all(is.na(got[, , 1])))                      # sentinel band -> nodata
  expect_equal(unname(got[1, 1, 2]), (90 / 127.5)^2, tolerance = 1e-4)
})

test_that("lazy_dataset(path) band subset by index reads only the selected bands", {
  dir <- withr::local_tempdir("mbsub")
  f <- .mb_cog(dir, codes = c(-40L, 50L, 90L))
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(64L, 64L), dtype = "f32")
  got <- collect(lazy_dataset(f, grid, bands = c(1L, 3L)), distributed = FALSE)
  expect_equal(dim(got), c(64L, 64L, 2L))
  expect_equal(unname(got[1, 1, 1]), -40)                  # band 1 raw code
  expect_equal(unname(got[1, 1, 2]),  90)                  # band 3 raw code
  expect_error(lazy_dataset(f, bands = 9L), "must index")
})

test_that("lazy_dataset(paths) mosaics a vector of same-CRS tiles", {
  mk_tile <- function(f, x0, code) {
    d <- gdalraster::create("GTiff", f, 256, 512, 1, "Int8", return_obj = TRUE,
                            options = c("TILED=YES", "BLOCKXSIZE=256",
                                        "BLOCKYSIZE=256"))
    d$setGeoTransform(c(x0, 10, 0, 5120, 0, -10))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    d$write(1, 0, 0, 256, 512, rep(code, 256 * 512))
    d$close()
    f
  }
  dir <- withr::local_tempdir("mbmos")
  left  <- mk_tile(file.path(dir, "L.tif"), 0,    -40L)
  right <- mk_tile(file.path(dir, "R.tif"), 2560,  90L)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(4L, 4L), dtype = "f32")
  got <- collect(lazy_dataset(c(left, right), grid), distributed = FALSE)
  expect_equal(dim(got), c(4L, 4L))                        # one band -> 2D matrix
  expect_true(all(got[, 1:2] == -40))                      # left cols from tile L
  expect_true(all(got[, 3:4] ==  90))                      # right cols from tile R
})

test_that("lazy_dataset(path) reads under distributed daemons (band fan-out)", {
  dir <- withr::local_tempdir("mbdist")
  f <- .mb_cog(dir)
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(128L, 128L), dtype = "f32")
  local_pools(2, 1, gdal_config = TRUE)
  got <- collect(lazy_map(lazy_dataset(f, grid), fn = dequantize_aef,
                          dtype = "f32"),
                 distributed = TRUE)
  ref <- function(x) ((x / 127.5)^2) * sign(x)
  expect_equal(dim(got), c(128L, 128L, 3L))
  expect_equal(unname(got[1, 1, 1]), ref(-40), tolerance = 1e-4)
  expect_equal(unname(got[64, 64, 3]), ref(90), tolerance = 1e-4)
})

test_that("lazy_dataset(path) survives no-nodata float sources holding exact zeros", {
  # Regression carried over from the retired cptkirk path: GDAL's "value 0
  # changed to 1.4e-45 to avoid being treated as NoData" warp warning must
  # not corrupt zeros (or abort) on a float source with no declared nodata.
  dir <- withr::local_tempdir("mbzero")
  f <- file.path(dir, "zero.tif")
  d <- gdalraster::create("GTiff", f, 512, 512, 2, "Float32",
                          return_obj = TRUE,
                          options = c("TILED=YES", "BLOCKXSIZE=256",
                                      "BLOCKYSIZE=256"))
  d$setGeoTransform(c(0, 10, 0, 5120, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  v <- rep(c(0, 1.5), each = 512 * 256)      # exact zeros, no declared nodata
  for (b in 1:2) d$write(b, 0, 0, 512, 512, v)
  d$close()
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 5120, 5120),
                    dims = c(128L, 128L), dtype = "f32")
  got <- collect(lazy_dataset(f, grid)[["b1"]], distributed = FALSE)
  expect_equal(unname(got[1, 1]), 0)
  expect_equal(unname(got[128, 1]), 1.5)
})
