# mlp_project(): a trained MLP as a custom band reducer. Gates: the fused
# body reproduces a plain per-pixel R forward pass exactly (untraced), the
# traced (PJRT) kernel matches the untraced oracle, a full band-stacked
# plan matches, NaN features poison exactly their own pixel
# (complete-cases semantics), and extracted torch weights drop in.

# per-pixel reference forward pass
.ref_mlp <- function(v, weights, biases, center = NULL, scale = NULL,
                     sigmoid = FALSE) {
  if (anyNA(v)) return(NaN)
  h <- v
  if (!is.null(center)) h <- h - center
  if (!is.null(scale)) h <- h / scale
  n <- length(weights)
  for (l in seq_len(n)) {
    h <- as.numeric(weights[[l]] %*% h) + biases[[l]]
    if (l < n) h <- pmax(h, 0)
  }
  if (sigmoid) 1 / (1 + exp(-h)) else h
}

.mk_weights <- function(n_in, hidden = 8L, seed = 42) {
  set.seed(seed)
  list(
    weights = list(
      matrix(rnorm(hidden * n_in, sd = 0.5), hidden, n_in),
      matrix(rnorm(hidden * hidden, sd = 0.5), hidden, hidden),
      matrix(rnorm(hidden, sd = 0.5), 1, hidden)
    ),
    biases = list(rnorm(hidden), rnorm(hidden), rnorm(1))
  )
}

.ref_plane <- function(cube, w, ...) {
  apply(cube, c(2, 3), .ref_mlp, weights = w$weights, biases = w$biases, ...)
}

test_that("the reducer matches a per-pixel forward pass (untraced)", {
  set.seed(1)
  n_in <- 5L
  w <- .mk_weights(n_in)
  cube <- array(rnorm(n_in * 6 * 4), c(n_in, 6, 4))
  cube[2, 3, 2] <- NaN                       # one poisoned pixel
  fn <- mlp_project(w$weights, w$biases)
  got <- fn(cube, 1L)
  want <- .ref_plane(cube, w)
  expect_equal(got, want, tolerance = 1e-12)
  expect_true(is.na(got[3, 2]))
  expect_identical(sum(is.na(got)), 1L)      # NaN stays per-pixel
})

test_that("standardisation and sigmoid output match the reference", {
  set.seed(2)
  n_in <- 4L
  w <- .mk_weights(n_in, hidden = 6L, seed = 7)
  ctr <- rnorm(n_in); scl <- runif(n_in, 0.5, 2)
  cube <- array(rnorm(n_in * 5 * 3), c(n_in, 5, 3))
  fn <- mlp_project(w$weights, w$biases, center = ctr, scale = scl,
                    output_activation = "sigmoid")
  want <- .ref_plane(cube, w, center = ctr, scale = scl, sigmoid = TRUE)
  expect_equal(fn(cube, 1L), want, tolerance = 1e-12)
})

test_that("traced (PJRT) kernel matches the untraced oracle", {
  skip_if_not_installed("anvl")
  set.seed(3)
  n_in <- 5L
  w <- .mk_weights(n_in)
  cube <- array(rnorm(n_in * 7 * 6), c(n_in, 7, 6))
  cube[4, 2, 5] <- NaN
  fn <- mlp_project(w$weights, w$biases)
  jf <- g_jit(function(x) fn(x, 1L))
  traced <- g_download(jf(g_upload(cube, "f32")))
  untraced <- fn(cube, 1L)
  expect_identical(is.na(traced), is.na(untraced))
  expect_equal(traced, untraced, tolerance = 1e-5)     # f32 kernel vs f64 oracle
})

test_that("a full band-stacked plan predicts through execute_plan", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  w <- .mk_weights(3L, hidden = 4L, seed = 11)
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  cube <- lazy_stack(list(a, a * 0.5, a - 2), along = "band")
  pred <- reduce_over(cube, mlp_project(w$weights, w$biases), over = "band")
  got <- execute_plan(plan_lazy(pred))

  m <- execute_plan(plan_lazy(lazy_source(f)))
  ref_cube <- array(NA_real_, c(3, dim(m)))
  ref_cube[1, , ] <- m
  ref_cube[2, , ] <- m * 0.5
  ref_cube[3, , ] <- m - 2
  expect_equal(got, .ref_plane(ref_cube, w), tolerance = 1e-4)
  # the reduce grid drops the band axis
  expect_identical(names(pred@grid@dims), c("x", "y"))
})

test_that("torch nn_linear weights drop in as-is", {
  skip_if_not_installed("torch")
  skip_if(!torch::torch_is_installed(), "libtorch not installed")
  set.seed(4)
  n_in <- 6L; hidden <- 8L
  net <- torch::nn_sequential(
    torch::nn_linear(n_in, hidden), torch::nn_relu(),
    torch::nn_dropout(0.2),
    torch::nn_linear(hidden, hidden), torch::nn_relu(),
    torch::nn_dropout(0.2),
    torch::nn_linear(hidden, 1)
  )
  net$eval()
  lin <- Filter(function(m) inherits(m, "nn_linear"), net$children)
  fn <- mlp_project(
    weights = lapply(lin, function(l) as.matrix(l$weight)),
    biases = lapply(lin, function(l) as.numeric(l$bias))
  )
  cube <- array(rnorm(n_in * 5 * 4), c(n_in, 5, 4))
  got <- fn(cube, 1L)
  X <- torch::torch_tensor(t(matrix(cube, n_in)))     # (npix, n_in)
  want <- matrix(as.numeric(net(X)), dim(cube)[2], dim(cube)[3])
  expect_equal(got, want, tolerance = 1e-6)
})

test_that("mlp_project validates its arguments", {
  w <- .mk_weights(3L)
  expect_error(mlp_project(w$weights, w$biases[1:2]), "equal-length")
  expect_error(mlp_project(w$weights[1:2], w$biases[1:2]),
               "one output")
  bad_b <- w$biases; bad_b[[2]] <- 1
  expect_error(mlp_project(w$weights, bad_b), "bias length")
  expect_error(mlp_project(w$weights, w$biases, center = 1:2),
               "per input band")
  fn <- mlp_project(w$weights, w$biases)
  cube <- array(rnorm(3 * 4 * 4), c(3, 4, 4))
  expect_error(fn(cube, 2L), "margin 1")
  expect_error(fn(array(0, c(4, 2, 2)), 1L), "chunk")
})
