# Phase 5 gate: end-to-end collect() on real GeoTIFFs vs whole-array
# pure-R references.


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
    focal_map(a + 1, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L),
    "mean", c("x", "y"), nan_rm = TRUE)

  old <- options(garry.chunk_target_px = 300)   # force multiple chunks
  on.exit(options(old))
  got <- collect(r)
  expect_equal(got, want, tolerance = 1e-5)
})

test_that("NDVI-style two-source pipeline matches plain R arithmetic", {
  # Two files on one grid, the second flipped north-south so the answer varies
  # pixel by pixel. A ratio of one source to itself, or to a multiple of it, is
  # constant everywhere and cannot show which pixel met which.
  red <- .fixture_values(60, 40)
  nir <- red[40:1, ]
  f_red <- fixture_gradient_f32()
  f_nir <- fixture_tile(
    as.numeric(t(nir)), gt = c(500000, 10, 0, 4600000, 0, -10),
    nx = 60L, ny = 40L, crs = "EPSG:32632"
  )

  g <- graph_new()
  a <- lazy_source(f_nir, graph = g)
  b <- lazy_source(f_red, graph = g)
  ndvi <- (a - b) / (a + b)

  old <- options(garry.chunk_target_px = 300)
  on.exit(options(old))
  got <- collect(ndvi)

  want <- (nir - red) / (nir + red)
  expect_equal(got, want, tolerance = 1e-5, ignore_attr = TRUE)
  expect_gt(length(unique(as.numeric(want))), 100L)
})

test_that("full-raster map materialises bit-exactly at f32", {
  f <- fixture_gradient_f32()
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  a <- lazy_source(f)
  got <- collect(a * 2 + 1)
  expect_equal(got, m * 2 + 1, tolerance = 0, ignore_attr = "gis")
  expect_identical(dim(got), c(40L, 60L))
})

test_that("scalar reduction sinks return scalars", {
  f <- fixture_gradient_f32()
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  a <- lazy_source(f)
  got <- collect(reduce_over(a, "max", c("x", "y")))
  expect_length(got, 1L)
  expect_equal(got, max(m), tolerance = 0)
})

test_that("a failed read aborts, naming the file and the cause", {
  f <- fixture_gradient_f32()
  meta <- gdal_grid_spec(f)
  ghost <- lazy_source(file.path(tempdir(), "garry-gone.tif"),
                       grid = meta$grid, block_dim = meta$block_dim)
  withr::local_options(garry.read_retry = 0L)
  err <- expect_error(.gdal_hushed(collect(ghost + 1), .gdal_missing("garry-gone.tif")),
                      class = "garry_read_error")
  expect_match(conditionMessage(err), "garry-gone.tif", fixed = TRUE)
  expect_match(conditionMessage(err), "No such file", fixed = TRUE)
})

test_that("collect() takes distributed as one flag", {
  x <- lazy_source(fixture_gradient_f32())
  expect_error(collect(x, distributed = "no"), "distributed", fixed = TRUE)
  expect_error(collect(x, distributed = NA), "distributed", fixed = TRUE)
})

test_that("a result past one outer dim says what to do", {
  err <- expect_error(garry:::.exec_rank_check(2L), class = "garry_plan_error")
  expect_match(conditionMessage(err), "reduce_over", fixed = TRUE)
  expect_no_error(garry:::.exec_rank_check(1L))
})
