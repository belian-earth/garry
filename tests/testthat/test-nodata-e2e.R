# Decision D8 end-to-end: i16 + nodata source through map, focal, and
# nan_rm reductions vs terra's na.rm = TRUE as the independent oracle.


test_that("nodata flows as NaN through map and reduce, matches terra", {
  skip_if_not_installed("terra")
  f <- fixture_i16_nodata()
  a <- lazy_source(f)                       # f32 with NaN (D8)
  r <- reduce_over(a * 2, "mean", c("x", "y"), nan_rm = TRUE)

  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old))
  got <- collect(r)

  rt <- terra::rast(f) * 2
  want <- terra::global(rt, "mean", na.rm = TRUE)[1, 1]
  expect_equal(got, want, tolerance = 1e-6)
})

test_that("focal over nodata: NaN propagates without nan-aware kernel", {
  f <- fixture_i16_nodata()
  m <- gdal_read_window(f, 1L, 0L, 0L, 70L, 50L,
                        nodata = gdal_grid_spec(f)$nodata)
  a <- lazy_source(f)
  expr <- focal_map(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old))
  got <- collect(expr)

  # Reference: 3x3 mean, NaN boundary, NaN propagation.
  padded <- matrix(NaN, 52, 72)
  padded[2:51, 2:71] <- m
  want <- matrix(0, 50, 70)
  for (dy in 0:2) for (dx in 0:2)
    want <- want + padded[(1 + dy):(50 + dy), (1 + dx):(70 + dx)]
  want <- want / 9
  expect_equal(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("nan-aware focal kernel shrinks the window instead", {
  f <- fixture_i16_nodata()
  m <- gdal_read_window(f, 1L, 0L, 0L, 70L, 50L,
                        nodata = gdal_grid_spec(f)$nodata)
  a <- lazy_source(f)
  nanmean9 <- function(sh) {
    vals <- Reduce(`+`, lapply(sh, function(s) g_ifelse(g_is_nodata(s), 0, s)))
    cnt <- Reduce(`+`, lapply(sh, function(s) g_cast(!g_is_nodata(s), "f32")))
    vals / cnt
  }
  got <- collect(focal_map(a, nanmean9, 1L))

  padded <- matrix(NaN, 52, 72)
  padded[2:51, 2:71] <- m
  want <- matrix(0, 50, 70); cnt <- matrix(0, 50, 70)
  for (dy in 0:2) for (dx in 0:2) {
    w <- padded[(1 + dy):(50 + dy), (1 + dx):(70 + dx)]
    want <- want + ifelse(is.nan(w), 0, w)
    cnt <- cnt + !is.nan(w)
  }
  want <- want / cnt
  expect_equal(got, want, tolerance = 1e-5, ignore_attr = "gis")
})

test_that("a focal over integer data without nodata has NaN edges", {
  f <- withr::local_tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", f, 6, 5, 1, "Int16", return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 50, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  ds$write(1, 0, 0, 6, 5, as.numeric(1:30))
  ds$close()
  x <- lazy_source(f)
  expect_identical(x@grid@dtype, "i16")
  for (fx in list(
    focal_map(x, radius = 1L, fn = function(sh) Reduce(`+`, sh) / 9),
    focal_kernel(x + 1L, matrix(1 / 9, 3, 3))
  )) {
    expect_identical(fx@grid@dtype, "f32")
    r <- collect(fx)
    expect_true(all(is.nan(r[c(1, 5), ])))
    expect_true(all(is.nan(r[, c(1, 6)])))
    expect_false(anyNA(r[2:4, 2:5]))
  }
  # other consumers of the same source still read integers
  expect_identical((x * 2L)@grid@dtype, "i16")
  expect_error(focal_map(x, radius = -1, fn = identity), "whole number")
})

test_that("comparisons keep nodata as nodata", {
  f <- fixture_i16_nodata() # has nodata cells
  x <- lazy_source(f, nodata = -9999)
  v <- collect(x)
  m <- collect(x > 50)
  expect_identical(is.nan(m), is.nan(v))
  expect_true(all(m[!is.nan(v)] %in% c(0, 1)))
  mm <- collect(x == x)
  expect_identical(is.nan(mm), is.nan(v))
  # the masked fraction skips nodata rather than counting it as "no"
  st <- lazy_stack(list(x, x))
  frac <- collect(reduce_over(st > 50, "mean", "t"))
  expect_identical(is.nan(frac), is.nan(v))
})

test_that("a given nodata replaces the file's own on every read", {
  f <- fixture_tile(c(0, 5, 7, 7), nodata = 0) # the file calls 0 nodata
  x <- lazy_source(f, nodata = 5)
  m <- collect(x, distributed = FALSE)
  expect_true(all(m[, 1L] == 0) && all(m[, 3:4] == 7))
  expect_true(all(is.nan(m[, 2L])))
  # the warper and a direct read agree
  wide <- grid_spec("EPSG:3857", extent = c(0, 0, 80, 40), dims = c(8L, 4L))
  w <- collect(align_to(x, wide), distributed = FALSE)
  expect_identical(as.numeric(w[, 1:4]), as.numeric(m))
  expect_true(all(is.nan(w[, 5:8])))
  crop <- grid_spec("EPSG:3857", extent = c(0, 0, 20, 40), dims = c(2L, 4L))
  expect_identical(as.numeric(collect(align_to(x, crop), distributed = FALSE)),
                   as.numeric(m[, 1:2]))
  expect_equal(as.numeric(extract_points(x, cbind(5, 35))), 0)
  # so do the file form, and a band of it the override leaves alone
  expect_equal(collect(lazy_dataset(f, nodata = 5), distributed = FALSE), m,
               ignore_attr = TRUE)
  two <- tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", two, 4L, 4L, 2L, "Float32", return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 40, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  for (b in 1:2) {
    ds$write(b, 0L, 0L, 4L, 4L, rep_len(c(0, 5, 7, 7), 16L))
    ds$setNoDataValue(b, 0)
    ds$setDescription(b, c("this", "other")[[b]])
  }
  ds$close()
  kept <- lazy_dataset(two, nodata = c(other = 5))
  this <- collect(kept$this, distributed = FALSE)
  other <- collect(kept$other, distributed = FALSE)
  expect_true(all(is.nan(this[, 1L])) && all(this[, 2L] == 5))
  expect_true(all(other[, 1L] == 0) && all(is.nan(other[, 2L])))
  # a key that names no band is refused, not read as no sentinel at all
  expect_error(lazy_dataset(two, nodata = c(othr = 5)), "othr",
               class = "garry_source_error")
  # a band of the file a selection leaves out is no typo
  expect_identical(names(lazy_dataset(two, bands = 1L, nodata = c(other = 5))), "this")
  # a declared sentinel given again changes nothing
  same <- lazy_source(f, nodata = 0)
  expect_identical(graph_get(same@graph, same@node_id)@path, f)
  # the file's scale survives the replacement
  sc <- fixture_tile(c(0, 5, 7, 7), nodata = 0, scale = 0.5)
  v <- collect(lazy_dataset(sc, nodata = 5, scale = TRUE), distributed = FALSE)
  expect_true(all(v[, 1L] == 0) && all(v[, 3L] == 3.5))
})

test_that("a given nodata keeps tiles apart, so a gap stays nodata", {
  a <- fixture_tile(c(0, 5, 7, 7), nodata = 0)
  b <- fixture_tile(c(0, 5, 7, 7), nodata = 0, gt = c(80, 10, 0, 40, 0, -10))
  ds <- lazy_dataset(c(a, b), nodata = 5)
  m <- collect(ds, distributed = FALSE)
  expect_true(all(m[, c(1L, 9L)] == 0))             # the tiles' 0 is data
  expect_true(all(is.nan(m[, c(2L, 10L)])))         # their 5 is not
  expect_true(all(is.nan(m[, 5:8])))                # nor is the gap
  # a sentinel the tiles declare keeps the mosaic
  same <- lazy_dataset(c(a, b), nodata = 0)[[1L]]
  expect_length(graph_get(same@graph, same@node_id)@path, 1L)
})
