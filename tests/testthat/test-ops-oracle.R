# The ops vocabulary vs base-R semantics on NaN-bearing arrays. This file
# is the oracle contract; Phase 5 extends it into the anvl parity harness
# (same cases, traced execution, f32 tolerance).

.nanful <- function(n, m, frac = 0.3, seed = 1) {
  set.seed(seed)
  x <- matrix(runif(n * m), n, m)
  x[sample(length(x), length(x) * frac)] <- NaN
  x
}

test_that("g_ifelse / g_is_nodata basics", {
  x <- .nanful(6, 5)
  masked <- g_ifelse(g_is_nodata(x), 0, x)
  expect_false(anyNA(masked))
  expect_identical(masked[!is.nan(x)], x[!is.nan(x)])
  expect_identical(dim(masked), dim(x))
})

test_that("g_pad and g_shift_slice reconstruct stencil neighbourhoods", {
  x <- matrix(as.numeric(1:20), 4, 5)
  xp <- g_pad(x, 1L, value = 0)
  expect_identical(dim(xp), c(6L, 7L))
  expect_identical(xp[2:5, 2:6], x)
  # Centre shift recovers x itself.
  expect_identical(g_shift_slice(xp, 0L, 0L, 4L, 5L, 1L), x)
  # Shift right by one column: last column falls into padding.
  s <- g_shift_slice(xp, 0L, 1L, 4L, 5L, 1L)
  expect_identical(s[, 1:4], x[, 2:5])
  expect_identical(s[, 5], rep(0, 4L))
  # 3x3 sum via shifts equals a hand loop.
  want <- matrix(0, 4, 5)
  xpn <- g_pad(x, 1L)
  for (dy in -1:1) for (dx in -1:1)
    want <- want + g_shift_slice(xpn, dy, dx, 4L, 5L, 1L)
  brute <- matrix(0, 4, 5)
  xd <- g_pad(x, 1L)
  for (i in 1:4) for (j in 1:5)
    brute[i, j] <- sum(xd[i:(i + 2), j:(j + 2)])
  expect_equal(want, brute)
})

test_that("reductions match base R with na.rm semantics", {
  x <- .nanful(8, 9)
  expect_equal(g_sum(x, nan_rm = TRUE), sum(x, na.rm = TRUE))
  expect_equal(g_mean(x, nan_rm = TRUE), mean(x, na.rm = TRUE))
  expect_true(is.nan(g_mean(x)))               # NaN propagates by default
  expect_equal(g_min(x, nan_rm = TRUE), min(x, na.rm = TRUE))
  expect_equal(g_max(x, nan_rm = TRUE), max(x, na.rm = TRUE))
  expect_equal(g_count(x), sum(!is.nan(x)))
})

test_that("axis reductions over 3D stacks match apply()", {
  set.seed(2)
  a <- array(runif(5 * 6 * 7), c(5, 6, 7))
  a[sample(length(a), 60)] <- NaN
  got <- g_mean(a, dims = 1L, nan_rm = TRUE)
  want <- apply(a, c(2, 3), function(v) mean(v, na.rm = TRUE))
  expect_equal(got, want)
  got2 <- g_sum(a, dims = c(2L, 3L), nan_rm = TRUE)
  want2 <- apply(a, 1, function(v) sum(v, na.rm = TRUE))
  expect_equal(got2, want2)
})

test_that("all-nodata slices follow XLA init-value semantics", {
  x <- matrix(NaN, 3, 4)
  expect_equal(g_sum(x, nan_rm = TRUE), 0)
  expect_identical(g_min(x, nan_rm = TRUE), Inf)
  expect_identical(g_max(x, nan_rm = TRUE), -Inf)
  expect_true(is.nan(g_mean(x, nan_rm = TRUE)))
  expect_true(is.nan(g_median(x, nan_rm = TRUE)))
  expect_equal(g_count(x), 0L)
})

test_that("g_median matches R and returns NaN, never NA", {
  v <- c(3, NaN, 1, 5, NaN)
  expect_equal(g_median(v, nan_rm = TRUE), 3)
  set.seed(3)
  a <- array(runif(3 * 4 * 4), c(3, 4, 4))
  a[, 2, 2] <- NaN
  got <- g_median(a, dims = 1L, nan_rm = TRUE)
  expect_true(is.nan(got[2, 2]))
  ok <- !is.nan(got)
  want <- apply(a, c(2, 3), function(v) median(v, na.rm = TRUE))
  expect_equal(got[ok], want[ok])
})

test_that("bitwise family decodes QA masks exactly", {
  set.seed(4)
  qa <- matrix(sample(0:65535, 30, replace = TRUE), 5, 6)
  cloud <- g_bitand(g_shiftr(qa, 10L), 1L)
  expect_identical(cloud, {
    r <- bitwAnd(bitwShiftR(as.integer(qa), 10L), 1L); dim(r) <- dim(qa); r
  })
  expect_identical(g_bitor(qa, 0L), {
    r <- as.integer(qa); dim(r) <- dim(qa); r
  })
  expect_identical(g_bitxor(qa, qa), {
    r <- rep(0L, 30); dim(r) <- dim(qa); r
  })
  expect_identical(g_shiftl(g_shiftr(qa, 4L), 4L),
                   g_bitand(qa, bitwNot(15L)))
})
