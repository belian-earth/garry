# THE correctness gate for chunked execution (D14): identical results
# across chunk sizes, including focal halos, on the anvl path.


test_that("map pipeline is chunk-invariant", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expr <- (a * 3 - 1) / (a + 100)

  whole <- .with_chunk_px(1e6, collect(expr))
  for (px in c(17 * 23, 32 * 32, 64 * 48)) {
    expect_equal(.with_chunk_px(px, collect(expr)), whole, tolerance = 1e-7,
                 label = paste("px", px))
  }
})

test_that("focal pipeline is chunk-invariant (halo across seams)", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expr <- focal_map(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  whole <- .with_chunk_px(1e6, collect(expr))
  for (px in c(17 * 23, 32 * 32)) {
    expect_equal(.with_chunk_px(px, collect(expr)), whole, tolerance = 1e-7,
                 label = paste("px", px))
  }
})

test_that("stacked focal_map (halo 3) is chunk-invariant", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  s9 <- function(sh) Reduce(`+`, sh)
  expr <- focal_map(focal_map(a, s9, 1L), s9, 2L)

  whole <- .with_chunk_px(1e6, collect(expr))
  got <- .with_chunk_px(19 * 19, collect(expr))
  expect_equal(got, whole, tolerance = 1e-5)
})

test_that("global reductions are chunk-invariant", {
  f <- fixture_i16_nodata()
  a <- lazy_source(f)                 # i16 + nodata -> f32 with NaN
  for (op in c("sum", "mean", "min", "max", "count")) {
    r <- reduce_over(a, op, c("x", "y"), nan_rm = TRUE)
    whole <- .with_chunk_px(1e6, collect(r))
    got <- .with_chunk_px(21 * 21, collect(r))
    expect_equal(got, whole, tolerance = 1e-6, label = op)
  }
})

test_that("an integer sum is chunk-invariant past its band's range", {
  vals <- rep_len(c(32767, 30000, 7, -5), 60 * 40)
  r <- reduce_over(lazy_source(fixture_tile(vals, "Int16", nx = 60L, ny = 40L)), "sum", c("x", "y"))
  for (px in c(1e6, 21 * 21)) {
    expect_equal(as.numeric(.with_chunk_px(px, collect(r))), sum(vals), tolerance = 0, label = paste("px", px))
  }
})
