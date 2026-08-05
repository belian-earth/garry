# NN ops for native OCM inference (P0): g_conv2d / g_upsample2x /
# g_pad_rb / g_transpose / g_erf. Gates: pure-R oracle == traced (anvl)
# on every parameterisation used by the model (stride, padding,
# dilation, groups incl. depthwise), and conv semantics == torch.

skip_if_not_installed("anvl")

.f32tol <- 1e-4

.arr <- function(seed, ...) {
  set.seed(seed)
  d <- c(...)
  array(runif(prod(d), -1, 1), d)
}

test_that("g_conv2d oracle matches traced across parameterisations", {
  x <- .arr(1, 6, 17, 13)
  cases <- list(
    list(w = .arr(2, 4, 6, 3, 3), stride = 1L, padding = 1L, groups = 1L),
    list(w = .arr(3, 8, 6, 1, 1), stride = 1L, padding = 0L, groups = 1L),
    list(w = .arr(4, 4, 6, 3, 3), stride = 2L, padding = 1L, groups = 1L),
    list(w = .arr(5, 6, 1, 3, 3), stride = 1L, padding = 1L, groups = 6L),
    list(w = .arr(6, 6, 3, 3, 3), stride = 1L, padding = 1L, groups = 2L),
    list(w = .arr(7, 4, 6, 3, 3), stride = 1L, padding = 2L, groups = 1L,
         dilation = 2L),
    list(w = .arr(8, 4, 6, 7, 7), stride = 1L, padding = 3L, groups = 1L))
  for (i in seq_along(cases)) {
    cs <- cases[[i]]
    dil <- cs$dilation %||% 1L
    bias <- runif(dim(cs$w)[[1L]])
    ref <- g_conv2d(x, cs$w, bias, stride = cs$stride, padding = cs$padding,
                    dilation = dil, groups = cs$groups)
    jf <- g_jit(function(inputs)
      g_conv2d(inputs[[1L]], cs$w, bias, stride = cs$stride,
               padding = cs$padding, dilation = dil, groups = cs$groups))
    got <- g_download(jf(list(g_upload(x, "f32"))))
    expect_equal(dim(got), dim(ref), label = paste("case", i))
    expect_lt(max(abs(got - ref)), .f32tol)
  }
})

test_that("g_conv2d matches torch", {
  skip_if_not_installed("torch")
  x <- .arr(10, 6, 15, 11)
  for (cs in list(list(co = 4, k = 3, stride = 1L, padding = 1L, groups = 1L),
                  list(co = 6, k = 3, stride = 2L, padding = 1L, groups = 6L),
                  list(co = 4, k = 5, stride = 1L, padding = 2L, groups = 2L))) {
    cig <- 6L %/% cs$groups
    w <- .arr(11, cs$co, cig, cs$k, cs$k)
    b <- runif(cs$co)
    ref <- torch::nnf_conv2d(
      torch::torch_tensor(array(x, c(1L, dim(x)))),
      torch::torch_tensor(w), bias = torch::torch_tensor(b),
      stride = cs$stride, padding = cs$padding, groups = cs$groups)
    ref <- as.array(ref)[1L, , , , drop = TRUE]
    got <- g_conv2d(x, w, b, stride = cs$stride, padding = cs$padding,
                    groups = cs$groups)
    expect_equal(got, ref, tolerance = 1e-6, ignore_attr = TRUE)
  }
})

test_that("g_upsample2x oracle matches traced", {
  x <- .arr(20, 3, 9, 7)
  ref <- g_upsample2x(x)
  expect_identical(dim(ref), c(3L, 18L, 14L))
  expect_identical(ref[2, 5, 6], x[2, 3, 3])       # 2x2 blocks
  jf <- g_jit(function(inputs) g_upsample2x(inputs[[1L]]))
  got <- g_download(jf(list(g_upload(x, "f32"))))
  expect_lt(max(abs(got - ref)), .f32tol)
})

test_that("g_pad_rb oracle matches traced and pads high side only", {
  x <- .arr(21, 3, 9, 7)
  ref <- g_pad_rb(x, 3L, 5L, value = 0)
  expect_identical(dim(ref), c(3L, 12L, 12L))
  expect_identical(ref[, 1:9, 1:7], x)
  expect_true(all(ref[, 10:12, ] == 0) && all(ref[, , 8:12] == 0))
  jf <- g_jit(function(inputs) g_pad_rb(inputs[[1L]], 3L, 5L, value = 0))
  got <- g_download(jf(list(g_upload(x, "f32"))))
  expect_lt(max(abs(got - ref)), .f32tol)

  m <- .arr(22, 5, 4)                              # rank-2 path
  expect_identical(dim(g_pad_rb(m, 1L, 2L)), c(6L, 6L))
})

test_that("g_transpose oracle matches traced", {
  x <- .arr(23, 4, 6, 5)
  for (perm in list(NULL, c(2L, 3L, 1L), c(1L, 3L, 2L))) {
    ref <- if (is.null(perm)) aperm(x) else aperm(x, perm)
    jf <- g_jit(function(inputs) g_transpose(inputs[[1L]], perm))
    got <- g_download(jf(list(g_upload(x, "f32"))))
    expect_lt(max(abs(got - ref)), .f32tol)
  }
})

test_that("g_erf oracle matches traced and base R", {
  x <- .arr(24, 5, 8)
  ref <- 2 * pnorm(x * sqrt(2)) - 1
  expect_equal(g_erf(x), ref, tolerance = 1e-12)
  jf <- g_jit(function(inputs) g_erf(inputs[[1L]]))
  got <- g_download(jf(list(g_upload(x, "f32"))))
  expect_lt(max(abs(got - ref)), .f32tol)
})
