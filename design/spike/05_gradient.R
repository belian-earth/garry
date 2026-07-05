# Spike 05: reverse-mode AD over a multi-stage pipeline.
# Warmup: linear model params. Main event: recover a 3x3 convolution
# kernel from input/output pairs by gradient descent — the Phase 6 exit
# criterion from the design doc, pulled forward.

library(anvl)

# -- Warmup: d(loss)/d(a, b) for y ~ a*x + b. ------------------------------
set.seed(5)
xr <- matrix(runif(64 * 64), 64, 64)
yr <- 2.5 * xr + 0.7

loss_lin <- function(a, b, x, y) mean((a * x + b - y)^2)
g_lin <- jit(gradient(loss_lin, wrt = c("a", "b")))
gr <- g_lin(nv_scalar(1.0, "f32"), nv_scalar(0.0, "f32"),
            nv_array(xr, "f32"), nv_array(yr, "f32"))
ga <- as_array(gr$a); gb <- as_array(gr$b)
# Analytic: d/da = 2*mean((a*x+b-y)*x), d/db = 2*mean(a*x+b-y) at a=1,b=0
want_a <- 2 * mean((xr - yr) * xr); want_b <- 2 * mean(xr - yr)
cat(sprintf("linear grads: got (%.5f, %.5f) want (%.5f, %.5f)\n", ga, gb, want_a, want_b))
stopifnot(abs(ga - want_a) < 1e-4, abs(gb - want_b) < 1e-4)

# -- Kernel recovery through a stencil. ------------------------------------
n <- 96L
conv3 <- function(x, k) {
  xpad <- nv_pad(x, nv_scalar(0, "f32"),
                 edge_padding_low = c(1L, 1L), edge_padding_high = c(1L, 1L))
  out <- NULL
  idx <- 1L
  for (dy in -1:1) {
    for (dx in -1:1) {
      sh <- nv_static_slice(xpad,
                            start_indices = c(2L + dy, 2L + dx),
                            limit_indices = c(n + 1L + dy, n + 1L + dx),
                            strides = c(1L, 1L))
      w <- nv_reshape(nv_static_slice(nv_flatten(k), idx, idx, 1L), integer(0))
      term <- sh * w
      out <- if (is.null(out)) term else out + term
      idx <- idx + 1L
    }
  }
  out
}

set.seed(6)
x_r <- matrix(runif(n * n), n, n)
k_true <- matrix(c(0.05, 0.1, 0.05, 0.1, 0.4, 0.1, 0.05, 0.1, 0.05), 3, 3)

x_a <- nv_array(x_r, "f32")
k_a <- nv_array(k_true, "f32")
y_a <- jit(conv3)(x_a, k_a)   # synthetic target from the true kernel

loss <- function(k, x, y) mean((conv3(x, k) - y)^2)
vg <- jit(value_and_gradient(loss, wrt = "k"))

k_est <- nv_array(matrix(1 / 9, 3, 3), "f32")   # flat init
lr <- 0.2
for (step in 1:300) {
  r <- vg(k_est, x_a, y_a)
  k_est <- nv_array(as_array(k_est) - lr * as_array(r$grad$k), "f32")
  if (step %% 100 == 0)
    cat(sprintf("step %3d loss %.3e\n", step, as_array(r$value)))
}
err <- max(abs(as_array(k_est) - k_true))
cat("recovered kernel, max abs error vs truth:", format(err), "\n")
print(round(as_array(k_est), 4))
stopifnot(err < 0.01)
cat("PASS: gradient() differentiates through composed stencil pipelines\n")
