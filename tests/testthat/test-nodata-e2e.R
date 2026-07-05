# Decision D8 end-to-end: i16 + nodata source through map, focal, and
# nan_rm reductions vs terra's na.rm = TRUE as the independent oracle.

skip_if_not_installed("anvl")

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
  expr <- focal(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

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
  got <- collect(focal(a, nanmean9, 1L))

  padded <- matrix(NaN, 52, 72)
  padded[2:51, 2:71] <- m
  want <- matrix(0, 50, 70); cnt <- matrix(0, 50, 70)
  for (dy in 0:2) for (dx in 0:2) {
    w <- padded[(1 + dy):(50 + dy), (1 + dx):(70 + dx)]
    want <- want + ifelse(is.nan(w), 0, w)
    cnt <- cnt + !is.nan(w)
  }
  want <- want / cnt
  expect_equal(got, want, tolerance = 1e-5)
})
