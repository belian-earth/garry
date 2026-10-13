# reduce_over() keeps a pixel that is nodata in every input as nodata for
# min and max, as it already does for mean and median. Gates: time and
# spatial reductions, single-process and pooled, chunked spatial partials,
# and the g_min()/g_max() primitives keeping their +/-Inf identity.

# A two-slice stack where the pixels with value <= 2000 are NaN in both
# slices.
.allnan_stack <- function() {
  x <- lazy_source(fixture_gradient_f32())
  a <- lazy_map(x, fn = function(v) g_ifelse(v > 2000, v, NaN))
  b <- lazy_map(x, fn = function(v) g_ifelse(v > 2000, v * 2, NaN))
  lazy_stack(list(a = a, b = b))
}

test_that("min and max over time leave all-nodata pixels as NaN", {
  stk <- .allnan_stack()
  ref <- collect(reduce_over(stk, "count", "t"), distributed = FALSE)
  expect_true(any(ref == 0) && any(ref > 0))
  for (op in c("min", "max", "mean", "median")) {
    v <- collect(reduce_over(stk, op, "t"), distributed = FALSE)
    expect_identical(is.nan(v), ref == 0, info = op)
    expect_false(any(is.infinite(v)), info = op)
  }
  expect_true(all(collect(reduce_over(stk, "sum", "t"), distributed = FALSE)[ref == 0] == 0))
})

test_that("spatial min and max of an all-nodata raster are NaN, chunked too", {
  x <- lazy_map(lazy_source(fixture_gradient_f32()), fn = function(v) v * NaN)
  for (px in c(1e9, 200)) {
    .with_chunk_px(px, {
      for (op in c("min", "max")) {
        v <- collect(reduce_over(x, op, c("x", "y")), distributed = FALSE)
        expect_true(all(is.nan(v)), info = paste(op, px))
      }
    })
  }
  # a raster with data still reduces to its extremes
  y <- lazy_source(fixture_gradient_f32())
  m <- collect(y, distributed = FALSE)
  expect_equal(as.numeric(collect(reduce_over(y, "max", c("x", "y")), distributed = FALSE)),
               max(m, na.rm = TRUE))
})

test_that("pooled min and max leave all-nodata pixels as NaN", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  stk <- .allnan_stack()
  ref <- collect(reduce_over(stk, "count", "t"), distributed = FALSE)
  local_pools(2, 1)
  for (op in c("min", "max")) {
    v <- collect(reduce_over(stk, op, "t"))
    expect_identical(is.nan(v), ref == 0, info = op)
  }
})

test_that("the g_min and g_max primitives keep their identity values", {
  a <- array(NaN, c(2, 3))
  expect_identical(unique(as.numeric(g_max(a, dims = 1L, nan_rm = TRUE))), -Inf)
  expect_identical(unique(as.numeric(g_min(a, dims = 1L, nan_rm = TRUE))), Inf)
})
