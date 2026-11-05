tiled_tif <- function(nx, ny, gt, crs, tile = 128L, env = parent.frame()) {
  f <- withr::local_tempfile(fileext = ".tif", .local_envir = env)
  ds <- gdalraster::create(
    "GTiff", f, nx, ny, 1, "Int16",
    options = c("TILED=YES", paste0("BLOCKXSIZE=", tile), paste0("BLOCKYSIZE=", tile)),
    return_obj = TRUE
  )
  ds$setGeoTransform(gt)
  ds$setProjection(gdalraster::srs_to_wkt(crs))
  ds$write(1, 0, 0, nx, ny, as.numeric(seq_len(nx * ny) %% 1000))
  ds$close()
  f
}

test_that("a plain read lists its windows, tiles and their bytes", {
  f <- system.file("extdata", "storml_elev.tif", package = "gdalraster")
  w <- plan_reads(lazy_source(f), distributed = FALSE)
  expect_identical(nrow(w), 1L)
  expect_identical(w$route, "read")
  expect_identical(w$path, f)
  expect_equal(unlist(w[c("x_off", "y_off", "x_size", "y_size")]), c(x_off = 0, y_off = 0, x_size = 143, y_size = 107))
  expect_equal(unlist(w[c("src_x_size", "src_y_size")]), c(src_x_size = 143, src_y_size = 107))
  # a striped file's tiles are its strips
  expect_equal(unlist(w[c("tile_x0", "tile_y0", "tile_x1", "tile_y1", "tile_x_size", "tile_y_size")]),
    c(tile_x0 = 0, tile_y0 = 0, tile_x1 = 0, tile_y1 = 3, tile_x_size = 143, tile_y_size = 28))

  t <- plan_reads(lazy_source(f), tiles = TRUE, distributed = FALSE)
  expect_identical(nrow(t), 4L)
  ds <- methods::new(gdalraster::GDALRaster, f)
  withr::defer(ds$close())
  expect_equal(t$offset, as.numeric(vapply(0:3, function(y) ds$getMetadataItem(1L, paste0("BLOCK_OFFSET_0_", y), "TIFF"), "")))
  expect_equal(t$length, as.numeric(vapply(0:3, function(y) ds$getMetadataItem(1L, paste0("BLOCK_SIZE_0_", y), "TIFF"), "")))
})

test_that("a computed plan's read windows cover its grid once", {
  f <- tiled_tif(1000, 600, c(500000, 30, 0, 4600000, 0, -30), "EPSG:32632")
  r <- lazy_source(f)
  withr::local_options(garry.chunk_target_px = 2^16, garry.read_target_px = 2^18)
  w <- plan_reads(r + 1, distributed = FALSE)
  expect_gt(nrow(w), 1L)
  expect_identical(sum(w$x_size * w$y_size), 1000 * 600)
  # a window's tiles are those its pixels fall in
  expect_equal(w$tile_x0, w$x_off %/% 128)
  expect_equal(w$tile_y1, (w$y_off + w$y_size - 1) %/% 128)
})

test_that("a warp lists the source window under each window's footprint", {
  f <- tiled_tif(1600, 400, c(60, 0.025, 0, -60, 0, -0.025), "EPSG:4326")
  target <- grid_spec("EPSG:3031", extent = c(1.5e6, -1e6, 3.5e6, 1e6), dims = c(1000L, 1000L), dtype = "f32")
  warped <- align_to(lazy_source(f, nodata = -32768), target, resampling = "bilinear")
  withr::local_options(garry.chunk_target_px = 2^18, garry.read_target_px = 2^18)
  w <- plan_reads(warped + 1, distributed = FALSE)
  # the source a warp reads itself is no read of its own
  expect_identical(unique(w$route), "warp")
  expect_true(all(w$path == f))
  # each footprint lies inside the box of the whole target's, with the kernel's pad
  whole <- gdalraster::transform_bounds(target@extent, target@crs, "EPSG:4326", densify_pts = 21L)
  cols <- (whole[c(1, 3)] - 60) / 0.025
  expect_true(all(w$src_x_off >= floor(cols[[1L]]) - 3 & w$src_x_off + w$src_x_size <= ceiling(cols[[2L]]) + 3, na.rm = TRUE))
  expect_true(all(w$tile_x_size == 128))
  expect_true(all(w$tile_x1 <= 1600 %/% 128 & w$tile_y1 <= 400 %/% 128, na.rm = TRUE))
  # a window's footprint is part of the source's, never more
  expect_true(all(w$src_x_size <= 1600 & w$src_y_size <= 400, na.rm = TRUE))
})

test_that("an aligned decimating read scales its window into the file", {
  f <- tiled_tif(512, 256, c(500000, 30, 0, 4600000, 0, -30), "EPSG:32632", tile = 64L)
  src <- lazy_source(f)
  half <- grid_spec(src@grid@crs, extent = src@grid@extent, dims = c(256L, 128L), dtype = "f32")
  w <- plan_reads(align_to(src, half, resampling = "near"), distributed = FALSE)
  expect_identical(w$route, "direct")
  expect_equal(w$src_x_size, 2 * w$x_size)
  expect_equal(w$src_y_size, 2 * w$y_size)
  expect_equal(c(w$tile_x1, w$tile_y1), c(7, 3))
})

test_that("a south-up file counts its tile rows from the south", {
  f <- withr::local_tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", f, 256, 256, 1, "Int16", options = c("TILED=YES", "BLOCKXSIZE=64", "BLOCKYSIZE=64"), return_obj = TRUE)
  ds$setGeoTransform(c(500000, 30, 0, 4592320, 0, 30))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$close()
  withr::local_options(garry.chunk_target_px = 64 * 64, garry.read_target_px = 64 * 64)
  w <- plan_reads(lazy_source(f) + 1, distributed = FALSE)
  north <- w[w$y_off == 0, ]
  expect_true(nrow(north) > 0)
  expect_true(all(north$tile_y0 == 3 & north$tile_y1 == 3))
})

test_that("reads of several files list their windows without a source window", {
  a <- tiled_tif(200, 100, c(500000, 30, 0, 4600000, 0, -30), "EPSG:32632")
  b <- tiled_tif(200, 100, c(506000, 30, 0, 4600000, 0, -30), "EPSG:32632")
  target <- grid_spec("EPSG:4326", extent = gdalraster::transform_bounds(c(500000, 4597000, 512000, 4600000), "EPSG:32632", "EPSG:4326"), dims = c(300L, 80L), dtype = "f32")
  ds <- lazy_dataset(c(a, b), grid = target, resampling = "bilinear", nodata = -32768)
  w <- plan_reads(ds, distributed = FALSE)
  expect_true(all(w$route %in% c("window_warp", "mosaic")))
  expect_true(all(is.na(w$src_x_off) & is.na(w$tile_x0)))
  expect_identical(nrow(plan_reads(ds, tiles = TRUE, distributed = FALSE)), 0L)
})

test_that("a VRT's tiles are its file's, found under each window", {
  f <- tiled_tif(256, 128, c(500000, 30, 0, 4600000, 0, -30), "EPSG:32632", tile = 64L)
  vrt <- withr::local_tempfile(fileext = ".vrt")
  gdalraster::buildVRT(vrt, f, quiet = TRUE)
  w <- plan_reads(lazy_source(vrt) + 1, distributed = FALSE)
  expect_identical(w$path, vrt)
  expect_equal(w$tile_x_size, 64)
  t <- plan_reads(lazy_source(vrt) + 1, tiles = TRUE, distributed = FALSE)
  expect_true(all(t$file == normalizePath(f)) || all(t$file == f))
  expect_identical(nrow(t), 8L)
  expect_true(all(t$offset > 0 & t$length > 0))
})

test_that("plan_reads() takes a plan as planned", {
  f <- system.file("extdata", "storml_elev.tif", package = "gdalraster")
  r <- lazy_source(f)
  expect_identical(plan_reads(plan_lazy(r), distributed = FALSE), plan_reads(r, distributed = FALSE))
})

test_that("a read onto a coarse grid lists the overview it reads", {
  m <- withr::local_tempfile(fileext = ".tif")
  f <- withr::local_tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", m, 2048, 2048, 1, "Int16", return_obj = TRUE)
  ds$setGeoTransform(c(500000, 30, 0, 4600000, 0, -30))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, 2048, 2048, as.numeric(seq_len(2048^2) %% 3000))
  ds$close()
  gdalraster::translate(m, f, cl_arg = c("-of", "COG", "-co", "BLOCKSIZE=256"), quiet = TRUE)
  src <- lazy_source(f)
  at <- function(k) {
    h <- methods::new(gdalraster::GDALRaster, f, TRUE, paste0("OVERVIEW_LEVEL=", k, " only"))
    withr::defer(h$close(), envir = parent.frame())
    h
  }

  # a decimating read takes the coarsest overview no coarser than itself
  by <- function(k) {
    g <- grid_spec(src@grid@crs, extent = src@grid@extent, dims = c(2048L, 2048L) %/% k, dtype = "f32")
    plan_reads(align_to(src, g, resampling = "near"), distributed = FALSE)
  }
  expect_identical(by(1)$overview, NA_integer_)
  two <- by(2)
  expect_identical(two$route, "direct")
  expect_identical(two$overview, 0L)
  four <- by(4)
  expect_identical(four$overview, 1L)
  expect_equal(c(four$src_x_size, four$src_y_size), c(512, 512))
  expect_equal(c(four$tile_x1, four$tile_y1), c(1, 1))

  # a warp onto a coarse grid reads the level its VRT names
  b <- gdalraster::transform_bounds(src@grid@extent, src@grid@crs, "EPSG:4326")
  w <- plan_reads(align_to(src, grid_spec("EPSG:4326", extent = b, dims = c(200L, 200L), dtype = "f32"), resampling = "bilinear"), distributed = FALSE)
  expect_identical(w$route, "warp")
  expect_gte(w$overview, 1L)
  ov <- at(w$overview)
  expect_lte(w$src_x_off + w$src_x_size, ov$getRasterXSize())
  expect_lte(w$src_y_off + w$src_y_size, ov$getRasterYSize())

  # and its tiles are the overview's, at the overview's offsets
  t <- plan_reads(align_to(src, grid_spec(src@grid@crs, extent = src@grid@extent, dims = c(512L, 512L), dtype = "f32"), resampling = "near"), tiles = TRUE, distributed = FALSE)
  expect_identical(unique(t$overview), 1L)
  expect_identical(nrow(t), 4L)
  o1 <- at(1L)
  expect_equal(t$offset, as.numeric(mapply(function(x, y) o1$getMetadataItem(1L, paste0("BLOCK_OFFSET_", x, "_", y), "TIFF"), t$tile_x, t$tile_y)))
})
