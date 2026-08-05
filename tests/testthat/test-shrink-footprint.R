# shrink_footprint(): NaN spreads by the radius from every nodata
# boundary, including the raster border (boundary = "nodata").

skip_if_not_installed("anvl")

test_that("shrink_footprint erodes nodata boundaries by the radius", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- collect(a)                      # single band: a (y, x) matrix

  # poke a nodata hole via algebra: NaN below a fixed threshold
  thr <- as.numeric(quantile(m, 0.05))
  lz <- lazy_map(a, dtype = "f32",
                 fn = function(x) g_ifelse(x <= thr, NaN, x))

  # oracle reference: dilate the NaN mask (incl. border) by r = 1
  ref <- m; ref[m <= thr] <- NaN
  bad <- !is.finite(ref)
  n <- nrow(ref); c <- ncol(ref)
  grown <- bad
  for (dy in -1:1) for (dx in -1:1) {
    ys <- seq_len(n) + dy; xs <- seq_len(c) + dx
    in_y <- ys >= 1L & ys <= n; in_x <- xs >= 1L & xs <= c
    g2 <- matrix(TRUE, n, c)                 # off-raster counts as nodata
    g2[in_y, in_x] <- bad[ys[in_y], xs[in_x]]
    grown <- grown | g2
  }
  exp <- ref; exp[grown] <- NaN

  out <- collect(shrink_footprint(lz, radius = 1L))
  expect_identical(!is.finite(out), !is.finite(exp))
  keep <- is.finite(exp)
  expect_equal(out[keep], exp[keep], tolerance = 1e-6)
})

test_that("shrink_footprint validates radius", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expect_error(shrink_footprint(a, radius = 0), "positive")
  expect_error(shrink_footprint(a, radius = c(1, 2)), "positive")
})
