# reduce_over(over = "band"): collapse the band axis with a custom anvl kernel.
# band_project() forms a linear combination of bands (spectral index / linear
# predict / PCA projection); stacking several gives multiple components.

.rb_cube <- function() {
  mk <- function(nm, m) {
    f <- file.path(tempdir(), nm)
    d <- gdalraster::create("GTiff", f, 4, 3, 1, "Float32", return_obj = TRUE)
    d$setGeoTransform(c(0, 10, 0, 30, 0, -10))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    d$write(1, 0, 0, 4, 3, as.numeric(t(m))); d$close(); f
  }
  g <- graph_new()
  mats <- lapply(1:3, function(k) outer(1:3, 1:4, function(r, c) k * 100 + r * 10 + c))
  cube <- lazy_stack(
    lapply(1:3, function(k)
      lazy_source(mk(sprintf("rb%d.tif", k), mats[[k]]), graph = g)),
    along = "band")
  list(cube = cube, mats = mats)   # mats: per-band [y, x] matrices
}

test_that("reduce_over(over = band) collapses the band axis", {
  skip_if_not_installed("anvl")
  rb <- .rb_cube()
  got <- collect(reduce_over(rb$cube, function(x, d) g_sum(x, d), over = "band"))
  expect_equal(got, Reduce(`+`, rb$mats), ignore_attr = "gis", tolerance = 1e-3)
})

test_that("band_project forms a per-pixel linear combination of bands", {
  skip_if_not_installed("anvl")
  rb <- .rb_cube(); w <- c(0.5, -0.3, 0.8)
  got  <- collect(reduce_over(rb$cube, band_project(w), over = "band"))
  want <- Reduce(`+`, Map(function(m, wk) wk * m, rb$mats, w))
  expect_equal(got, want, ignore_attr = "gis", tolerance = 1e-3)
})

test_that("band_project centres each band before weighting", {
  skip_if_not_installed("anvl")
  rb <- .rb_cube(); w <- c(1, 1, 1); ctr <- c(10, 20, 30)
  got  <- collect(reduce_over(rb$cube, band_project(w, center = ctr), over = "band"))
  want <- Reduce(`+`, Map(function(m, wk, ck) wk * (m - ck), rb$mats, w, ctr))
  expect_equal(got, want, ignore_attr = "gis", tolerance = 1e-3)
})

test_that("stacked band_projects give multiple components (PCA-style)", {
  skip_if_not_installed("anvl")
  rb <- .rb_cube()
  W <- matrix(c(0.5, -0.3, 0.8, 0.1, 0.9, -0.2), nrow = 3)   # 3 bands x 2 comps
  pcs <- lazy_stack(
    lapply(1:2, function(i) reduce_over(rb$cube, band_project(W[, i]), over = "band")),
    along = "band")
  got <- collect(pcs)                                        # (y, x, 2)
  expect_equal(dim(got), c(3L, 4L, 2L))
  for (i in 1:2) {
    want <- Reduce(`+`, Map(function(m, wk) wk * m, rb$mats, W[, i]))
    expect_equal(got[, , i], want, tolerance = 1e-3)
  }
})

test_that("band_project rejects a mismatched center", {
  expect_error(band_project(c(1, 2, 3), center = c(0, 0)), "same length")
})
