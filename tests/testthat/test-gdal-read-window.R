# Windowed reads: ragged edges, halo-enlarged windows, nodata -> NaN.

test_that("edge windows clip and read exactly", {
  f <- fixture_gradient_f32()
  # Bottom-right ragged corner: 0-based (55, 35), size 5x5.
  w <- gdal_read_window(f, 1L, 55L, 35L, 5L, 5L)
  want <- outer(36:40, 56:60, function(r2, c2) r2 * 100 + c2)
  expect_identical(w, want)
})

test_that("halo-enlarged windows read what chunk_window_with_halo says", {
  f <- fixture_gradient_f32()
  meta <- gdal_grid_spec(f)
  cg <- ChunkGrid(grid = meta$grid, chunk_dim = c(16L, 16L),
                  block_dim = c(1L, 1L), halo = 2L)
  it <- chunk_iter(cg)
  full <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)

  for (j in seq_len(nrow(it))) {
    w <- chunk_window_with_halo(cg, it$x_off[j], it$y_off[j],
                                it$x_size[j], it$y_size[j])
    got <- gdal_read_window(f, 1L, w$x_off, w$y_off, w$x_size, w$y_size)
    want <- full[(w$y_off + 1):(w$y_off + w$y_size),
                 (w$x_off + 1):(w$x_off + w$x_size), drop = FALSE]
    expect_identical(got, want)
  }
})

test_that("i16 nodata cells arrive as NaN, values as numeric", {
  f <- fixture_i16_nodata()
  meta <- gdal_grid_spec(f)
  m <- gdal_read_window(f, 1L, 0L, 0L, 70L, 50L, nodata = meta$nodata)
  expect_true(is.nan(m[1, 1]))
  expect_true(all(is.nan(m[10:14, 20:24])))
  expect_identical(sum(is.nan(m)), 26L)          # 25-block + corner
  # Non-nodata values intact.
  expect_identical(m[2, 2], 202)
  expect_identical(m[50, 70], 5070)
})

test_that("windowed nodata read only rewrites the sentinel", {
  f <- fixture_i16_nodata()
  meta <- gdal_grid_spec(f)
  # Window over the nodata block: 0-based cols 18..26, rows 8..15.
  w <- gdal_read_window(f, 1L, 18L, 8L, 9L, 8L, nodata = meta$nodata)
  want_nan <- matrix(FALSE, 8, 9)
  want_nan[2:6, 2:6] <- TRUE   # rows 10:14, cols 20:24 within the window
  expect_identical(is.nan(w), want_nan)
})
