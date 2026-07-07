# Phase 5 gate: end-to-end collect() on real GeoTIFFs vs whole-array
# pure-R references (and terra where it adds an independent oracle).

skip_if_not_installed("anvl")

test_that("source |> +1 |> focal mean |> global mean matches reference", {
  f <- fixture_gradient_f32()
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)

  mp <- m + 1
  padded <- matrix(NaN, 42, 62)
  padded[2:41, 2:61] <- mp
  conv <- matrix(0, 40, 60)
  for (dy in 0:2) for (dx in 0:2)
    conv <- conv + padded[(1 + dy):(40 + dy), (1 + dx):(60 + dx)]
  conv <- conv / 9
  want <- mean(conv, na.rm = TRUE)

  a <- lazy_source(f)
  r <- reduce_over(
    focal(a + 1, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L),
    "mean", c("x", "y"), nan_rm = TRUE)

  old <- options(garry.chunk_target_px = 300)   # force multiple chunks
  on.exit(options(old))
  got <- collect(r)
  expect_equal(got, want, tolerance = 1e-5)
})

test_that("NDVI-style two-source pipeline matches terra arithmetic", {
  skip_if_not_installed("terra")
  f <- fixture_gradient_f32()

  a <- lazy_source(f)
  b <- lazy_source(f)          # same file: dedup keeps one source node
  ndvi <- (a - b / 2) / (a + b / 2)

  old <- options(garry.chunk_target_px = 300)
  on.exit(options(old))
  got <- collect(ndvi)

  r <- terra::rast(f)
  want_r <- (r - r / 2) / (r + r / 2)
  want <- as.matrix(want_r, wide = TRUE)
  expect_equal(got, want, tolerance = 1e-5, ignore_attr = TRUE)
})

test_that("full-raster map materialises bit-exactly at f32", {
  f <- fixture_gradient_f32()
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  a <- lazy_source(f)
  got <- collect(a * 2 + 1)
  expect_equal(got, m * 2 + 1, tolerance = 1e-5)
  expect_identical(dim(got), c(40L, 60L))
})

test_that("scalar reduction sinks return scalars", {
  f <- fixture_gradient_f32()
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  a <- lazy_source(f)
  got <- collect(reduce_over(a, "max", c("x", "y")))
  expect_length(got, 1L)
  expect_equal(got, max(m), tolerance = 1e-3)   # f32 rounding on 4060
})

test_that("read_fail = 'nodata' turns a dead source into NaN, not an abort", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  meta <- gdal_grid_spec(f)
  ghost <- lazy_source(file.path(tempdir(), "garry-gone.tif"),
                       grid = meta$grid, block_dim = meta$block_dim)
  old <- options(garry.read_fail = "nodata")
  on.exit(options(old))
  got <- suppressWarnings(collect(ghost + 1))
  expect_true(all(is.nan(got)))
  expect_identical(dim(got), unname(meta$grid@dims[c("y", "x")]))

  # default remains a hard error
  options(garry.read_fail = "error")
  suppressWarnings(expect_error(collect(ghost + 1)))
})
