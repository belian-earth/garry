# THE correctness gate for chunked execution (D14): identical results
# across chunk sizes, including focal halos, on the anvl path.

skip_if_not_installed("anvl")

.collect_with_px <- function(x, px) {
  old <- options(garry.chunk_target_px = px)
  on.exit(options(old))
  collect(x)
}

test_that("map pipeline is chunk-invariant", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expr <- (a * 3 - 1) / (a + 100)

  whole <- .collect_with_px(expr, 1e6)
  for (px in c(17 * 23, 32 * 32, 64 * 48)) {
    expect_equal(.collect_with_px(expr, px), whole, tolerance = 1e-7,
                 label = paste("px", px))
  }
})

test_that("focal pipeline is chunk-invariant (halo across seams)", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expr <- focal(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  whole <- .collect_with_px(expr, 1e6)
  for (px in c(17 * 23, 32 * 32)) {
    expect_equal(.collect_with_px(expr, px), whole, tolerance = 1e-7,
                 label = paste("px", px))
  }
})

test_that("stacked focal (halo 3) is chunk-invariant", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  s9 <- function(sh) Reduce(`+`, sh)
  expr <- focal(focal(a, s9, 1L), s9, 2L)

  whole <- .collect_with_px(expr, 1e6)
  got <- .collect_with_px(expr, 19 * 19)
  expect_equal(got, whole, tolerance = 1e-5)
})

test_that("global reductions are chunk-invariant", {
  f <- fixture_i16_nodata()
  a <- lazy_source(f)                 # i16 + nodata -> f32 with NaN
  for (op in c("sum", "mean", "min", "max", "count")) {
    r <- reduce_over(a, op, c("x", "y"), nan_rm = TRUE)
    whole <- .collect_with_px(r, 1e6)
    got <- .collect_with_px(r, 21 * 21)
    expect_equal(got, whole, tolerance = 1e-6, label = op)
  }
})
