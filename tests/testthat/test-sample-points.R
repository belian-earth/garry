# sample_points(): gather a lazy raster/dataset's values at points without
# materialising the raster. Expectations are closed-form on the .gg_grid
# geometry (EPSG:3857, extent 0..600 x 0..400, 10 m cells), so
# col = floor(x / 10), row = floor((400 - y) / 10), and cell (r, c) holds
# .gg_val()[r + 1, c + 1].

# A single-band f32 source on the .gg_grid geometry holding `vals` ([y, x]).
.sp_src <- function(vals, dir = withr::local_tempdir(.local_envir = parent.frame())) {
  f <- file.path(dir, paste0("sp-", substr(rlang::hash(vals), 1L, 8L), ".tif"))
  d <- gdalraster::create("GTiff", f, 60, 40, 1, "Float32", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 400, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$setNoDataValue(1, -9999)
  v <- vals
  v[is.na(v)] <- -9999
  d$write(1, 0, 0, 60, 40, as.numeric(t(v)))
  d$close()
  lazy_source(f)
}

# cell (r, c) 0-based -> the world coordinate of its CENTRE
.sp_centre <- function(r, c) wk::xy(c * 10 + 5, 400 - (r * 10 + 5), crs = "EPSG:3857")

test_that("nearest sampling takes the containing cell exactly", {
  vals <- .gg_val(0)
  x <- .sp_src(vals)
  # three interior cells plus one point outside the raster
  p <- wk::xy(c(5, 15, 595, 1000), c(395, 385, 5, 5), crs = "EPSG:3857")
  got <- sample_points(x, p, distributed = FALSE)
  expect_equal(dim(got), c(4L, 1L))
  expect_equal(as.numeric(got)[1:3], c(vals[1, 1], vals[2, 2], vals[40, 60]))
  expect_true(is.na(got[4L, 1L]))            # outside -> NA row, order kept
})

test_that("bilinear weights the four surrounding cell centres", {
  vals <- .gg_val(0)
  x <- .sp_src(vals)
  # exactly on the corner where cells (0,0) (0,1) (1,0) (1,1) meet
  p <- wk::xy(10, 390, crs = "EPSG:3857")
  got <- sample_points(x, p, method = "bilinear", distributed = FALSE)
  expect_equal(
    as.numeric(got),
    mean(c(vals[1, 1], vals[1, 2], vals[2, 1], vals[2, 2]))
  )
  # a quarter of a cell in from that corner: weights 0.5625/0.1875/0.1875/0.0625
  p2 <- wk::xy(7.5, 392.5, crs = "EPSG:3857")
  got2 <- sample_points(x, p2, method = "bilinear", distributed = FALSE)
  expect_equal(
    as.numeric(got2),
    0.5625 * vals[1, 1] + 0.1875 * vals[1, 2] +
      0.1875 * vals[2, 1] + 0.0625 * vals[2, 2]
  )
  # at a cell centre bilinear reduces to that cell
  expect_equal(
    as.numeric(sample_points(x, .sp_centre(3, 4), method = "bilinear",
                             distributed = FALSE)),
    vals[4, 5]
  )
})

test_that("bilinear renormalises over the valid contributors", {
  vals <- .gg_val(0)
  vals[2, 2] <- NA                       # one contributor is nodata
  x <- .sp_src(vals)
  got <- sample_points(x, wk::xy(10, 390, crs = "EPSG:3857"),
                       method = "bilinear", distributed = FALSE)
  expect_equal(as.numeric(got),
               mean(c(vals[1, 1], vals[1, 2], vals[2, 1])))
  # every contributor invalid -> NaN, not a silent zero
  gone <- .gg_val(0)
  gone[1:2, 1:2] <- NA
  expect_true(is.na(as.numeric(sample_points(
    .sp_src(gone), wk::xy(10, 390, crs = "EPSG:3857"),
    method = "bilinear", distributed = FALSE))))
})

test_that("bilinear renormalises at the raster edge", {
  vals <- .gg_val(0)
  x <- .sp_src(vals)
  # inside cell (0,0) but in its outer quarter: three contributors fall
  # off the raster, so the survivor carries all the weight
  got <- sample_points(x, wk::xy(2, 398, crs = "EPSG:3857"),
                       method = "bilinear", distributed = FALSE)
  expect_equal(as.numeric(got), vals[1, 1])
})

test_that("results follow input order and carry band names", {
  vals <- .gg_val(0)
  x <- .sp_src(vals)
  cells <- list(c(0, 0), c(7, 3), c(39, 59), c(2, 11))
  pts <- wk::xy(
    vapply(cells, function(rc) rc[[2L]] * 10 + 5, numeric(1)),
    vapply(cells, function(rc) 400 - (rc[[1L]] * 10 + 5), numeric(1)),
    crs = "EPSG:3857")
  got <- sample_points(x, pts, distributed = FALSE)
  expect_equal(
    as.numeric(got),
    vapply(cells, function(rc) vals[rc[[1L]] + 1L, rc[[2L]] + 1L], numeric(1))
  )
  ds <- as_dataset(list(A = x, B = lazy_map(x, fn = function(v) v * 2)))
  gotd <- sample_points(ds, pts, distributed = FALSE)
  expect_equal(dim(gotd), c(4L, 2L))
  expect_equal(colnames(gotd), c("A", "B"))
  expect_equal(gotd[, "B"], gotd[, "A"] * 2)
})

test_that("points reproject onto the target grid", {
  vals <- .gg_val(0)
  x <- .sp_src(vals)
  native <- .sp_centre(5, 9)
  ll <- gdalraster::transform_xy(
    cbind(unclass(native)$x, unclass(native)$y),
    gdalraster::srs_to_wkt("EPSG:3857"), gdalraster::srs_to_wkt("EPSG:4326"))
  p4326 <- wk::xy(ll[, 1L], ll[, 2L], crs = "EPSG:4326")
  expect_equal(
    as.numeric(sample_points(x, p4326, distributed = FALSE)),
    as.numeric(sample_points(x, native, distributed = FALSE))
  )
})

test_that("pts must be a wk_xy carrying a CRS", {
  x <- .sp_src(.gg_val(0))
  expect_error(sample_points(x, cbind(5, 395), distributed = FALSE), "wk_xy")
  expect_error(sample_points(x, wk::xy(5, 395), distributed = FALSE), "no CRS")
})

test_that("sampling is identical distributed and single-process", {
  vals <- .gg_val(0)
  vals[10:12, 10:12] <- NA                       # a masked patch to cross
  x <- .sp_src(vals)
  set.seed(7)
  pts <- wk::xy(stats::runif(50, 0, 600), stats::runif(50, 0, 400),
                crs = "EPSG:3857")
  local_pools(2, 1)
  for (m in c("nearest", "bilinear")) {
    a <- sample_points(x, pts, method = m, distributed = FALSE)
    b <- sample_points(x, pts, method = m, distributed = TRUE)
    expect_identical(a, b, label = m)
  }
})

test_that("a bilinear neighbourhood straddling a chunk boundary is exact", {
  vals <- .gg_val(0)
  x <- .sp_src(vals)
  # the whole-raster answer, then the same points under a tiny chunk grid
  p <- wk::xy(c(100, 200, 305), c(300, 200, 155), crs = "EPSG:3857")
  ref <- sample_points(x, p, method = "bilinear", distributed = FALSE)
  .with_chunk_px(64, {
    got <- sample_points(x, p, method = "bilinear", distributed = FALSE)
    expect_identical(got, ref)
  })
  local_pools(2, 1)
  .with_chunk_px(64, {
    expect_identical(
      sample_points(x, p, method = "bilinear", distributed = TRUE), ref)
  })
})
