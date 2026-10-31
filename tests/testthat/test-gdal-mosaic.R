# The paths a dataset's first band reads.
.src_paths <- function(ds) {
  x <- ds[[1L]]
  graph_get(x@graph, x@node_id)@path
}

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

test_that("a multi-band mosaic that skipped a tile is an error, not a hole", {
  mk <- function(x0, nb) {
    f <- withr::local_tempfile(fileext = ".tif", .local_envir = parent.frame(2))
    d <- gdalraster::create("GTiff", f, 4, 4, nb, "Float32", return_obj = TRUE)
    d$setGeoTransform(c(x0, 10, 0, 40, 0, -10))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    for (b in seq_len(nb)) d$write(b, 0, 0, 4, 4, rep(b, 16))
    d$close()
    f
  }
  files <- c(mk(0, 3), mk(40, 3), mk(80, 2)) # buildVRT skips the 2-band tile
  expect_error(
    suppressWarnings(gdal_mosaic_vrt(withr::local_tempfile(fileext = ".vrt"), files)),
    "took 2 of 3"
  )
})

test_that("tiles off one lattice need a grid, and then warp onto it", {
  a <- fixture_tile(1)
  coarse <- fixture_tile(2, gt = c(40, 20, 0, 40, 0, -20), nx = 2L, ny = 2L)
  shifted <- fixture_tile(3, gt = c(45, 10, 0, 40, 0, -10))
  expect_error(lazy_dataset(c(a, coarse)), class = "garry_source_error")
  expect_error(lazy_dataset(c(a, shifted)), class = "garry_source_error")
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 80, 40), dims = c(8L, 4L), dtype = "f32")
  m <- collect(lazy_dataset(c(a, coarse), g), distributed = FALSE)
  expect_true(all(m[, 1:4] == 1) && all(m[, 5:8] == 2))
  # one lattice: still a mosaic, and the next tile along joins it
  b <- fixture_tile(4, gt = c(40, 10, 0, 40, 0, -10))
  x <- lazy_dataset(c(a, b))[[1L]]
  expect_length(graph_get(x@graph, x@node_id)@path, 1L)
  expect_identical(x@grid@dims, c(x = 8L, y = 4L))
})

test_that("sources kept as one node must agree on the metadata it takes from them", {
  south <- c(40, 10, 0, 0, 0, 10) # no mosaic holds a south-up tile
  a <- fixture_tile(1, nodata = -9999)
  b <- fixture_tile(2, nodata = -32768, gt = south)
  expect_error(lazy_dataset(c(a, b)), class = "garry_source_error")
  # a given nodata settles it for every source
  expect_length(.src_paths(lazy_dataset(c(a, b), nodata = -1)), 2L)
  expect_error(lazy_dataset(c(a, fixture_tile(2, "Int16", nodata = -9999, gt = south))),
               class = "garry_source_error")
  scaled <- fixture_tile(2, nodata = -9999, gt = south, scale = 0.5)
  expect_error(lazy_dataset(c(a, scaled), scale = TRUE), class = "garry_source_error")
  expect_length(.src_paths(lazy_dataset(c(a, scaled))), 2L)
})

test_that("several sources on their planning grid read by the given resampling", {
  a <- fixture_tile(c(1, 9))
  # a tile in another projection, just east of the first
  b <- fixture_tile(c(1, 9), gt = c(0.00036, 0.00009, 0, 0.00036, 0, -0.00009),
                    crs = "EPSG:4326")
  bil <- lazy_dataset(c(a, b), resampling = "bilinear")
  near <- lazy_dataset(c(a, b))
  expect_identical(graph_get(bil[[1L]]@graph, bil[[1L]]@node_id)@resampling, "bilinear")
  m_b <- collect(bil, distributed = FALSE)
  m_n <- collect(near, distributed = FALSE)
  expect_false(isTRUE(all.equal(as.numeric(m_b), as.numeric(m_n))))
})

test_that("a gap between tiles with no sentinel is missing, not 0", {
  far <- c(80, 10, 0, 40, 0, -10)
  m <- collect(lazy_dataset(c(fixture_tile(1), fixture_tile(2, gt = far))),
               distributed = FALSE)
  expect_true(all(is.nan(m[, 5:8])))
  expect_true(all(m[, 1:4] == 1) && all(m[, 9:12] == 2))
  ints <- lazy_dataset(c(fixture_tile(1, "Int16"), fixture_tile(2, "Int16", gt = far)))
  expect_error(collect(ints[[1L]] + 1L, distributed = FALSE), class = "garry_nodata_error")
  # a sentinel marks a gap, so those tiles keep the mosaic
  held <- lazy_dataset(c(fixture_tile(1, nodata = -9), fixture_tile(2, nodata = -9, gt = far)))
  expect_length(.src_paths(held), 1L)
  expect_true(all(is.nan(collect(held, distributed = FALSE)[, 5:8])))
  # as do tiles that fill their box, in any arrangement
  tiles <- c(fixture_tile(1), fixture_tile(2, gt = c(40, 10, 0, 40, 0, -10)),
             fixture_tile(3, gt = c(0, 20, 0, 0, 0, -20), nx = 4L, ny = 1L))
  expect_error(lazy_dataset(tiles), class = "garry_source_error") # off the lattice
  tiles[[3L]] <- fixture_tile(3, gt = c(0, 10, 0, 0, 0, -10), nx = 8L, ny = 2L)
  expect_length(.src_paths(lazy_dataset(tiles)), 1L)
})
