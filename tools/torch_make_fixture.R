# Generate the torch fixture for garry's conv, batch norm and MLP tests.
#
# Run once, from the package root, on a machine with torch and libtorch:
#
#     Rscript tools/torch_make_fixture.R
#
# Writes tests/testthat/fixtures/torch/conv-bn-mlp.rds. torch computes in f32,
# so inputs are saved after f32 rounding and both sides see identical values.
# test-ops-conv.R, test-safetensors.R and test-reduce-mlp.R compare garry
# against the saved outputs, so the tests hold without torch installed.

out <- "tests/testthat/fixtures/torch/conv-bn-mlp.rds"

# What torch_tensor() keeps of a double, as a double.
.f32 <- function(x) {
  v <- readBin(writeBin(as.numeric(x), raw(), size = 4L), "numeric", n = length(x), size = 4L)
  array(v, dim(x) %||% length(x))
}

.arr <- function(seed, ...) {
  set.seed(seed)
  d <- c(...)
  array(stats::runif(prod(d), -1, 1), d)
}

.batched <- function(x) torch::torch_tensor(array(x, c(1L, dim(x))))

# Standard, depthwise with stride, and grouped convolutions with bias.
conv_x <- .f32(.arr(10, 6, 9, 7))
conv <- lapply(
  list(
    list(co = 4L, k = 3L, stride = 1L, padding = 1L, groups = 1L),
    list(co = 6L, k = 3L, stride = 2L, padding = 1L, groups = 6L),
    list(co = 4L, k = 5L, stride = 1L, padding = 2L, groups = 2L)
  ),
  function(cs) {
    w <- .f32(.arr(11, cs$co, 6L %/% cs$groups, cs$k, cs$k))
    b <- as.numeric(.f32(stats::runif(cs$co)))
    ref <- torch::nnf_conv2d(
      .batched(conv_x),
      torch::torch_tensor(w),
      bias = torch::torch_tensor(b),
      stride = cs$stride,
      padding = cs$padding,
      groups = cs$groups
    )
    c(cs[c("stride", "padding", "groups")], list(
      w = w,
      b = b,
      ref = as.array(ref)[1L, , , , drop = TRUE]
    ))
  }
)

# A convolution then eval-mode batch norm, which .ocm_fold_conv_bn() folds.
set.seed(2)
co <- 5L
ci <- 3L
bn <- list(
  w = .f32(array(stats::runif(co * ci * 9, -1, 1), c(co, ci, 3, 3))),
  gamma = as.numeric(.f32(stats::runif(co, 0.5, 2))),
  beta = as.numeric(.f32(stats::runif(co, -1, 1))),
  mu = as.numeric(.f32(stats::runif(co, -1, 1))),
  var = as.numeric(.f32(stats::runif(co, 0.5, 2))),
  x = .f32(array(stats::runif(ci * 5 * 5, -1, 1), c(ci, 5, 5)))
)
bn$ref <- as.array(torch::nnf_batch_norm(
  torch::nnf_conv2d(.batched(bn$x), torch::torch_tensor(bn$w), padding = 1L),
  running_mean = torch::torch_tensor(bn$mu),
  running_var = torch::torch_tensor(bn$var),
  weight = torch::torch_tensor(bn$gamma),
  bias = torch::torch_tensor(bn$beta),
  training = FALSE,
  eps = 1e-5
))[1, , , , drop = TRUE]

# A trained-shape net: as.matrix(layer$weight) is what mlp_project() promises
# to take, so weights and biases are saved exactly as R reads them back.
set.seed(4)
torch::torch_manual_seed(4)
n_in <- 6L
hidden <- 8L
net <- torch::nn_sequential(
  torch::nn_linear(n_in, hidden), torch::nn_relu(),
  torch::nn_dropout(0.2),
  torch::nn_linear(hidden, hidden), torch::nn_relu(),
  torch::nn_dropout(0.2),
  torch::nn_linear(hidden, 1)
)
net$eval()
lin <- Filter(function(m) inherits(m, "nn_linear"), net$children)
cube <- .f32(array(stats::rnorm(n_in * 5 * 4), c(n_in, 5, 4)))
mlp <- list(
  weights = unname(lapply(lin, function(l) as.matrix(l$weight))),
  biases = unname(lapply(lin, function(l) as.numeric(l$bias))),
  cube = cube,
  want = matrix(
    as.numeric(net(torch::torch_tensor(t(matrix(cube, n_in))))),
    dim(cube)[[2L]],
    dim(cube)[[3L]]
  )
)

dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
saveRDS(
  list(
    meta = list(
      generator = "tools/torch_make_fixture.R",
      oracle = paste("torch", utils::packageVersion("torch")),
      r = R.version.string,
      date = format(Sys.Date())
    ),
    cases = list(conv = list(x = conv_x, cases = conv), bn = bn, mlp = mlp)
  ),
  out,
  version = 2,
  compress = "xz"
)
