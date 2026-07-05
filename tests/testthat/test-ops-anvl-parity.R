# The anvl parity harness: every op in the vocabulary, traced through
# jit(), must match the pure-R oracle on NaN-bearing inputs to f32
# tolerance. Extends test-ops-oracle.R (decision D9/D14).

skip_if_not_installed("anvl")

.f32tol <- 1e-5

.parity2d <- function(seed = 30, n = 24, m = 17, frac = 0.25) {
  set.seed(seed)
  x <- matrix(runif(n * m), n, m)
  x[sample(length(x), length(x) * frac)] <- NaN
  x
}

test_that("elementwise ops match under tracing", {
  x <- .parity2d()
  y <- .parity2d(seed = 31)

  jf <- g_jit(function(inputs) {
    a <- inputs[[1L]]; b <- inputs[[2L]]
    list(
      arith  = (a - b) / (a + b + 2),
      select = g_ifelse(g_is_nodata(a), 0, a),
      isnd   = g_cast(g_is_nodata(a), "f32"),
      casted = g_cast(a * 10, "i32")
    )
  })
  got <- g_download(jf(list(g_upload(x, "f32"), g_upload(y, "f32"))))

  expect_equal(got$arith, (x - y) / (x + y + 2), tolerance = .f32tol)
  expect_equal(got$select, g_ifelse(g_is_nodata(x), 0, x),
               tolerance = .f32tol)
  expect_equal(got$isnd, matrix(as.numeric(is.nan(x)), nrow(x)),
               tolerance = 0)
  # i32 cast truncates toward zero; NaN cells are undefined in XLA int
  # casts, so compare valid cells only.
  ok <- !is.nan(x)
  expect_equal(got$casted[ok], trunc(x[ok] * 10), tolerance = 0)
})

test_that("pad and shifted slices match under tracing", {
  x <- .parity2d(seed = 32, frac = 0)
  n <- nrow(x); m <- ncol(x)
  jf <- g_jit(function(inputs) {
    xp <- g_pad(inputs[[1L]], 1L, value = 0)
    list(
      centre = g_shift_slice(xp, 0L, 0L, n, m, 1L),
      ne     = g_shift_slice(xp, -1L, 1L, n, m, 1L)
    )
  })
  got <- g_download(jf(list(g_upload(x, "f32"))))
  xp <- g_pad(x, 1L, value = 0)
  expect_equal(got$centre, x, tolerance = .f32tol)
  expect_equal(got$ne, g_shift_slice(xp, -1L, 1L, n, m, 1L),
               tolerance = .f32tol)
})

test_that("reductions match under tracing (2D and 3D, nan_rm both ways)", {
  x <- .parity2d(seed = 33)
  set.seed(34)
  a3 <- array(runif(5 * 12 * 9), c(5, 12, 9))
  a3[sample(length(a3), 120)] <- NaN

  jf <- g_jit(function(inputs) {
    x2 <- inputs[[1L]]; x3 <- inputs[[2L]]
    list(
      s  = g_sum(x2, nan_rm = TRUE),
      mn = g_mean(x2, nan_rm = TRUE),
      lo = g_min(x2, nan_rm = TRUE),
      hi = g_max(x2, nan_rm = TRUE),
      ct = g_count(x2),
      tmean = g_mean(x3, dims = 1L, nan_rm = TRUE),
      tmed  = g_median(x3, dims = 1L, nan_rm = TRUE),
      poison = g_mean(x2)                     # NaN propagates
    )
  })
  got <- g_download(jf(list(g_upload(x, "f32"), g_upload(a3, "f32"))))

  expect_equal(got$s, g_sum(x, nan_rm = TRUE), tolerance = .f32tol)
  expect_equal(got$mn, g_mean(x, nan_rm = TRUE), tolerance = .f32tol)
  expect_equal(got$lo, g_min(x, nan_rm = TRUE), tolerance = .f32tol)
  expect_equal(got$hi, g_max(x, nan_rm = TRUE), tolerance = .f32tol)
  expect_equal(got$ct, g_count(x), tolerance = 0)
  expect_equal(got$tmean, g_mean(a3, dims = 1L, nan_rm = TRUE),
               tolerance = .f32tol)
  oracle_med <- g_median(a3, dims = 1L, nan_rm = TRUE)
  expect_equal(got$tmed, oracle_med, tolerance = .f32tol)
  expect_true(is.nan(got$poison))
})

test_that("bitwise family matches under tracing", {
  set.seed(35)
  qa <- matrix(sample(0:65535, 60, replace = TRUE), 6, 10)

  jf <- g_jit(function(inputs) {
    q <- inputs[[1L]]
    list(
      cloud = g_bitand(g_shiftr(q, 10L), 1L),
      orred = g_bitor(q, 255L),
      xored = g_bitxor(q, 43690L),
      shl   = g_shiftl(g_shiftr(q, 4L), 4L)
    )
  })
  got <- g_download(jf(list(g_upload(qa, "i32"))))

  expect_equal(got$cloud, g_bitand(g_shiftr(qa, 10L), 1L), tolerance = 0)
  expect_equal(got$orred, g_bitor(qa, 255L), tolerance = 0)
  expect_equal(got$xored, g_bitxor(qa, 43690L), tolerance = 0)
  expect_equal(got$shl, g_shiftl(g_shiftr(qa, 4L), 4L), tolerance = 0)
})
