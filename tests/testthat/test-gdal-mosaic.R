test_that("gdal_mosaic_vrt refuses a mosaic that lost a source instead of leaving a hole", {
  skip_if_not_installed("gdalraster")
  dir <- withr::local_tempdir()
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
  expect_error(gdal_mosaic_vrt(file.path(dir, "m.vrt"), c(a, b)), "skipped|failed")
  expect_false(file.exists(file.path(dir, "m.vrt")))
})

test_that("tiles the mosaic cannot hold stay a multi-path node the warper reads together", {
  skip_if_not_installed("gdalraster")
  dir <- withr::local_tempdir()
  srs <- gdalraster::epsg_to_wkt(32722)
  south_up <- function(path, x0, values) {   # 3 bands, 4 x 4, one value per band
    ds <- gdalraster::create("GTiff", path, 4L, 4L, 3L, "Int16", return_obj = TRUE)
    ds$setProjection(srs)
    ds$setGeoTransform(c(x0, 10, 0, 7900000, 0, 10))
    for (b in 1:3) ds$write(b, 0L, 0L, 4L, 4L, rep(values[[b]], 16L))
    ds$close()
    path
  }
  a <- south_up(file.path(dir, "a.tif"), 100000, c(1L, 10L, 100L))
  b <- south_up(file.path(dir, "b.tif"), 100040, c(2L, 20L, 200L))
  tg <- grid_spec(srs, extent = c(100000, 7900000, 100080, 7900040), res = 10)
  src_of <- function(lr) {
    n <- graph_get(lr@graph, lr@node_id)
    while (!S7::S7_inherits(n, SourceNode)) n <- graph_get(lr@graph, n@parents[[1L]])
    n
  }
  d <- lazy_dataset(c(a, b), tg, resampling = "near")
  # the source node carries both paths; the direct read path declines it
  src <- src_of(d@bands[[1L]][[1L]])
  expect_length(src@path, 2L)
  expect_null(.rio_direct_spec(src@path, tg, "near", band = 1L))
  # the planning grid is the union of both footprints, north-up
  expect_lt(src@grid@transform[[6L]], 0)
  expect_equal(unname(src@grid@extent), c(100000, 7900000, 100080, 7900040))
  # every band reads both tiles
  for (k in 1:3) {
    out <- file.path(dir, sprintf("b%d.tif", k))
    write_tif(lazy_dataset(c(a, b), tg, resampling = "near", assets = sprintf("b%d", k)), out, dtype = "i16")
    ds <- gdalraster::GDALRaster$new(out)
    vals <- as.integer(ds$read(1L, 0L, 0L, 8L, 4L, 8L, 4L)); ds$close()
    expect_equal(sort(unique(vals)), sort(c(1L, 2L) * 10L^(k - 1L)))
  }
  # a tile in a neighbouring projection joins the same way
  c_path <- file.path(dir, "c.tif")
  gdalraster::warp(b, c_path, t_srs = "EPSG:32721", cl_arg = c("-r", "near"), quiet = TRUE)
  out <- file.path(dir, "ac.tif")
  write_tif(lazy_dataset(c(a, c_path), tg, resampling = "near", assets = "b1"), out, dtype = "i16")
  ds <- gdalraster::GDALRaster$new(out)
  vals <- as.integer(ds$read(1L, 0L, 0L, 8L, 4L, 8L, 4L)); ds$close()
  expect_true(all(c(1L, 2L) %in% vals))
  # aligned north-up tiles still take the mosaic (one path, a VRT)
  north_up <- function(path, x0, value) {
    ds <- gdalraster::create("GTiff", path, 4L, 4L, 1L, "Int16", return_obj = TRUE)
    ds$setProjection(srs); ds$setGeoTransform(c(x0, 10, 0, 7900040, 0, -10))
    ds$write(1L, 0L, 0L, 4L, 4L, rep(value, 16L)); ds$close(); path
  }
  n1 <- north_up(file.path(dir, "n1.tif"), 100000, 5L); n2 <- north_up(file.path(dir, "n2.tif"), 100040, 6L)
  dn <- lazy_dataset(c(n1, n2), tg, resampling = "near")
  srcn <- src_of(dn@bands[[1L]][[1L]])
  expect_length(srcn@path, 1L); expect_match(srcn@path, "\\.vrt$")
})
