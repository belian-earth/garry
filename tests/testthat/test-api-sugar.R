# API ergonomics from the datamodel review: comparison / ^ / %% Ops and
# the Math group on LazyRaster+LazyDataset, grid_diff() embedded in
# alignment aborts, as_terra() from the gis attribute, and fill_gaps()
# (ffill / bfill / linear) as scan_over bodies.

skip_if_not_installed("anvl")

test_that("comparisons produce f32 0/1 masks that compose", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- collect(a)
  expect_equal(collect(a > 50), (m > 50) * 1, tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(collect(50 < a), (m > 50) * 1, tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(collect(a <= 50), (m <= 50) * 1, tolerance = 1e-6,
               ignore_attr = TRUE)
  g <- graph_new()
  b <- lazy_source(f, graph = g)
  expect_equal(collect((b * 2) == (b + b)), matrix(1, 40, 60),
               tolerance = 0, ignore_attr = TRUE)
  expect_equal(collect(b != b), matrix(0, 40, 60), tolerance = 0,
               ignore_attr = TRUE)
  # composes as map algebra: (x > 50) * x
  expect_equal(collect((a > 50) * a), (m > 50) * m, tolerance = 1e-5,
               ignore_attr = TRUE)
  expect_identical((a > 50)@grid@dtype, "f32")
})

test_that("^ and %% work on rasters and datasets", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- collect(a)
  expect_equal(collect(a^2), m^2, tolerance = 1e-5, ignore_attr = TRUE)
  expect_equal(collect(a %% 7), m %% 7, tolerance = 1e-5,
               ignore_attr = TRUE)
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(V = list(s1 = src())))
  out <- collect(reduce_over(ds^2, "mean", "t"))
  expect_equal(out, m^2, tolerance = 1e-5, ignore_attr = TRUE)
})

test_that("Math group generics map elementwise on raster and dataset", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- collect(a)
  expect_equal(collect(sqrt(a)), sqrt(m), tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(collect(log(a)), log(m), tolerance = 1e-5,
               ignore_attr = TRUE)
  expect_equal(collect(abs(a - 50)), abs(m - 50), tolerance = 1e-5,
               ignore_attr = TRUE)
  expect_equal(collect(round(a / 7)), round(m / 7), tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_error(cumsum(a), "scan_over")
  g <- graph_new()
  ds <- as_dataset(list(V = list(s1 = lazy_source(f, graph = g))))
  out <- collect(reduce_over(sqrt(ds), "mean", "t"))
  expect_equal(out, sqrt(m), tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("grid_diff names the first differing component, aborts embed it", {
  g1 <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400), dims = c(60L, 40L))
  g2 <- grid_spec("EPSG:32632", extent = c(0, 0, 600, 400), dims = c(60L, 40L))
  expect_match(grid_diff(g1, g2), "CRS differs")
  g3 <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400), dims = c(30L, 20L))
  expect_match(grid_diff(g1, g3), "resolution differs")
  g4 <- grid_spec("EPSG:3857", extent = c(3, 0, 603, 400), dims = c(60L, 40L))
  expect_match(grid_diff(g1, g4), "extents differ by 0.3 px in x")
  expect_match(grid_diff(g1, g1), "grids are equal")

  f <- fixture_gradient_f32()
  meta <- gdal_grid_spec(f)
  a <- lazy_source(f)
  shifted <- GridSpec(crs = meta$grid@crs,
                      transform = meta$grid@transform + c(3, 0, 0, 0, 0, 0),
                      extent = meta$grid@extent + c(3, 0, 3, 0),
                      dims = meta$grid@dims, dtype = meta$grid@dtype)
  b <- lazy_source(f, grid = shifted, block_dim = meta$block_dim)
  expect_error(a + b, "extents differ")
})

test_that("as_terra round-trips geometry and values", {
  skip_if_not_installed("terra")
  f <- fixture_gradient_f32()
  out <- collect(lazy_source(f) + 0)
  r <- as_terra(out)
  gis <- attr(out, "gis")
  expect_equal(unname(dim(r)[1:2]), c(nrow(out), ncol(out)))
  expect_equal(as.vector(terra::ext(r)),
               gis$bbox[c(1L, 3L, 2L, 4L)], ignore_attr = TRUE)
  expect_equal(terra::as.matrix(r, wide = TRUE), out,
               tolerance = 1e-6, ignore_attr = TRUE)
  expect_error(as_terra(matrix(1, 2, 2)), "gis")
})

test_that("fill_gaps ffill/bfill/linear match the plain-R oracle", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  hole <- function(x) lazy_map(x, fn = function(v)
    g_ifelse(v > 50, NaN, v), dtype = "f32")
  s <- lazy_stack(list(s1 = a + 0, s2 = hole(a), s3 = a * 2), along = "t")
  cube <- collect(s)                       # (y, x, 3)
  m1 <- cube[, , 1]; m2 <- cube[, , 2]; m3 <- cube[, , 3]
  gap <- is.nan(m2)

  ff <- collect(fill_gaps(s, "ffill"))
  expect_equal(ff[, , 2][gap], m1[gap], tolerance = 1e-6)
  expect_equal(ff[, , 2][!gap], m2[!gap], tolerance = 1e-6)
  expect_equal(ff[, , 1], m1, tolerance = 1e-6)

  bf <- collect(fill_gaps(s, "bfill"))
  expect_equal(bf[, , 2][gap], m3[gap], tolerance = 1e-6)

  li <- collect(fill_gaps(s, "linear"))
  expect_equal(li[, , 2][gap], ((m1 + m3) / 2)[gap], tolerance = 1e-5)
  expect_equal(li[, , 2][!gap], m2[!gap], tolerance = 1e-6)
  # a leading gap falls back to bfill
  s2 <- lazy_stack(list(s1 = hole(a), s2 = a * 2), along = "t")
  li2 <- collect(fill_gaps(s2, "linear"))
  c2 <- collect(s2)
  gap2 <- is.nan(c2[, , 1])
  expect_equal(li2[, , 1][gap2], c2[, , 2][gap2], tolerance = 1e-6)
})

test_that("fill_gaps on a dataset fills each value band", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  hole <- function(x) lazy_map(x, fn = function(v)
    g_ifelse(v > 50, NaN, v), dtype = "f32")
  ds <- as_dataset(list(V = list(s1 = a + 0, s2 = hole(a))))
  filled <- fill_gaps(ds, "ffill")
  out <- collect(filled[["V"]])
  base <- collect(a + 0)
  expect_equal(out[, , 2][base > 50], base[base > 50], tolerance = 1e-6)
})
