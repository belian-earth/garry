# Decision D5 lock: cross_grid_window is a planning estimate that must
# CONTAIN the true input window. Same-CRS is exact; cross-CRS relies on
# GDAL's densified transform_bounds, which corner-only math cannot match.

test_that("same-CRS mapping is exact vs brute force per-cell mapping", {
  set.seed(45)
  for (i in 1:50) {
    # Two grids, same CRS, different origin/resolution.
    in_g  <- grid_spec("EPSG:3857", extent = c(-50, -80, 70, 40),
                       dims = c(sample(20:120, 1), sample(20:120, 1)))
    out_g <- grid_spec("EPSG:3857", extent = c(-30, -60, 50, 20),
                       dims = c(sample(20:120, 1), sample(20:120, 1)))

    xo <- sample(0:(out_g@dims[1] - 5), 1)
    yo <- sample(0:(out_g@dims[2] - 5), 1)
    xs <- sample(1:(out_g@dims[1] - xo), 1)
    ys <- sample(1:(out_g@dims[2] - yo), 1)

    got <- cross_grid_window(out_g, in_g, xo, yo, xs, ys, margin = 0L)

    # Brute force: map every corner of every cell in the output window
    # into input pixel space; the true window is the bounding box.
    gt_o <- out_g@transform; gt_i <- in_g@transform
    cx <- seq(xo, xo + xs); cy <- seq(yo, yo + ys)
    corners <- expand.grid(px = cx, py = cy)
    wx <- gt_o[1] + corners$px * gt_o[2]
    wy <- gt_o[4] + corners$py * gt_o[6]
    ipx <- (wx - gt_i[1]) / gt_i[2]
    ipy <- (wy - gt_i[4]) / gt_i[6]
    x_lo <- max(0L, floor(min(ipx))); x_hi <- min(in_g@dims[1], ceiling(max(ipx)))
    y_lo <- max(0L, floor(min(ipy))); y_hi <- min(in_g@dims[2], ceiling(max(ipy)))
    x_hi <- max(x_hi, x_lo); y_hi <- max(y_hi, y_lo)

    expect_identical(got$x_off, as.integer(x_lo))
    expect_identical(got$y_off, as.integer(y_lo))
    expect_identical(got$x_size, as.integer(x_hi - x_lo))
    expect_identical(got$y_size, as.integer(y_hi - y_lo))
  }
})

# Truth harness for cross-CRS cases: densify the output window boundary
# with `n` points per edge, transform the points, and take the pixel
# bounding box on the input grid.
.densified_truth <- function(out_g, in_g, xo, yo, xs, ys, n = 400) {
  gt_o <- out_g@transform
  px <- seq(xo, xo + xs, length.out = n)
  py <- seq(yo, yo + ys, length.out = n)
  boundary <- rbind(
    cbind(px, yo), cbind(px, yo + ys),   # top, bottom edges
    cbind(xo, py), cbind(xo + xs, py)    # left, right edges
  )
  wx <- gt_o[1] + boundary[, 1] * gt_o[2]
  wy <- gt_o[4] + boundary[, 2] * gt_o[6]
  pts <- gdalraster::transform_xy(cbind(wx, wy), out_g@crs, in_g@crs)
  gt_i <- in_g@transform
  ipx <- (pts[, 1] - gt_i[1]) / gt_i[2]
  ipy <- (pts[, 2] - gt_i[4]) / gt_i[6]
  list(x_lo = floor(min(ipx)), x_hi = ceiling(max(ipx)),
       y_lo = floor(min(ipy)), y_hi = ceiling(max(ipy)))
}

test_that("cross-CRS windows contain the densified-boundary truth", {
  # 4326 output over a UTM 32N input at high latitude: parallels bow in
  # transverse Mercator, so corner-only bounds under-cover.
  in_g <- grid_spec("EPSG:32632",
                    extent = c(200000, 6600000, 900000, 6900000),
                    dims = c(700L, 300L))          # 1 km pixels
  out_g <- grid_spec("EPSG:4326",
                     extent = c(3, 59.5, 15, 62),
                     dims = c(480L, 100L))

  # Window spanning the zone: lon 3..15E, lat 60..61.5N.
  xo <- 0L; yo <- 20L; xs <- 480L; ys <- 60L

  got <- cross_grid_window(out_g, in_g, xo, yo, xs, ys)
  truth <- .densified_truth(out_g, in_g, xo, yo, xs, ys)

  expect_lte(got$x_off, max(0, truth$x_lo))
  expect_lte(got$y_off, max(0, truth$y_lo))
  expect_gte(got$x_off + got$x_size, min(in_g@dims[1], truth$x_hi))
  expect_gte(got$y_off + got$y_size, min(in_g@dims[2], truth$y_hi))
})

test_that("corner-only math under-covers where boundaries curve (regression)", {
  # The failure class the old 2-corner implementation belonged to: bound
  # the window by transforming corners only, no densification. At 60N in
  # UTM the bottom edge dips below both bottom corners near the central
  # meridian, so the corner-only ymax (row direction) under-covers.
  in_g <- grid_spec("EPSG:32632",
                    extent = c(200000, 6600000, 900000, 6900000),
                    dims = c(700L, 300L))
  out_g <- grid_spec("EPSG:4326",
                     extent = c(3, 59.5, 15, 62),
                     dims = c(480L, 100L))
  xo <- 0L; yo <- 20L; xs <- 480L; ys <- 60L

  gt_o <- out_g@transform
  cpx <- c(xo, xo + xs, xo, xo + xs)
  cpy <- c(yo, yo, yo + ys, yo + ys)
  wx <- gt_o[1] + cpx * gt_o[2]
  wy <- gt_o[4] + cpy * gt_o[6]
  pts <- gdalraster::transform_xy(cbind(wx, wy), out_g@crs, in_g@crs)
  gt_i <- in_g@transform
  ipy <- (pts[, 2] - gt_i[4]) / gt_i[6]
  corner_y_hi <- ceiling(max(ipy))

  truth <- .densified_truth(out_g, in_g, xo, yo, xs, ys)
  # Corner-only misses rows the densified truth needs...
  expect_lt(corner_y_hi, truth$y_hi)
  # ...while cross_grid_window covers them.
  got <- cross_grid_window(out_g, in_g, xo, yo, xs, ys)
  expect_gte(got$y_off + got$y_size, min(in_g@dims[2], truth$y_hi))
})

test_that("windows outside the input grid clip to zero size", {
  a <- grid_spec("EPSG:3857", extent = c(0, 0, 100, 100), dims = c(100L, 100L))
  b <- grid_spec("EPSG:3857", extent = c(1000, 1000, 1100, 1100),
                 dims = c(100L, 100L))
  w <- cross_grid_window(a, b, 0L, 0L, 50L, 50L, margin = 0L)
  expect_identical(w$x_size, 0L)
  expect_identical(w$y_size, 0L)
})
