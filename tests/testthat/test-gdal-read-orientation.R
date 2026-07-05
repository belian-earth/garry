# Decision D13 lock: [row = y, col = x], row 1 = northernmost. The
# asymmetric fixture (value = row*100 + col) makes any transpose or flip
# produce loud mismatches; spot checks go through world coordinates so
# the test is anchored to geography, not to array conventions.

test_that("full read matches the generator formula", {
  f <- fixture_gradient_f32()
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  expect_identical(dim(m), c(40L, 60L))         # [y, x]
  expect_identical(m[1, 1], 101)                 # top-left = row1 col1
  expect_identical(m[1, 60], 160)                # top-right
  expect_identical(m[40, 1], 4001)               # bottom-left
  expect_identical(m[40, 60], 4060)              # bottom-right
  expect_identical(m[7, 23], 723)                # interior spot
})

test_that("values agree with terra at world coordinates", {
  skip_if_not_installed("terra")
  f <- fixture_gradient_f32()
  r <- terra::rast(f)
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  g <- gdal_grid_spec(f)$grid
  gt <- g@transform

  set.seed(20)
  for (i in 1:25) {
    col <- sample(60, 1); row <- sample(40, 1)
    # World coordinates of the cell centre under garry's conventions.
    wx <- gt[1] + (col - 0.5) * gt[2]
    wy <- gt[4] + (row - 0.5) * gt[6]
    want <- terra::extract(r, cbind(wx, wy))[1, 1]
    expect_identical(m[row, col], want)
  }
})

test_that("windowed reads take the right sub-block", {
  f <- fixture_gradient_f32()
  # 0-based window: cols 11..15, rows 3..8 (1-based: cols 12:16, rows 4:9).
  w <- gdal_read_window(f, 1L, 11L, 3L, 5L, 6L)
  expect_identical(dim(w), c(6L, 5L))
  want <- outer(4:9, 12:16, function(r2, c2) r2 * 100 + c2)
  expect_identical(w, want)
})
