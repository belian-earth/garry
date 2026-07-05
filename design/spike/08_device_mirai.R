# Spike 08: CUDA device + jit under a mirai daemon.
# (a) Is a CUDA PJRT plugin available and does jit(device=) route to it?
# (b) Can a mirai daemon compile and run kernels, receiving an R matrix
#     and returning an R matrix (chunk-task shape of the executor)?

library(anvl)

# -- (a) CUDA --------------------------------------------------------------
cuda_ok <- tryCatch({
  a <- nv_array(matrix(runif(16), 4, 4), "f32", device = "cuda")
  f <- jit(function(x) x * 2, device = "cuda")
  r <- as_array(f(a))
  max(abs(r)) > 0
}, error = function(e) {
  cat("CUDA path failed:", conditionMessage(e), "\n")
  FALSE
})
cat("CUDA jit round-trip:", if (isTRUE(cuda_ok)) "OK" else "UNAVAILABLE", "\n")

if (isTRUE(cuda_ok)) {
  s <- 2048L
  m1 <- matrix(runif(s * s), s, s); m2 <- matrix(runif(s * s), s, s)
  k_cpu <- jit(function(a, b) ((a - b) / (a + b)) * 2, device = "cpu")
  k_gpu <- jit(function(a, b) ((a - b) / (a + b)) * 2, device = "cuda")
  invisible(as_array(k_cpu(nv_array(m1, "f32"), nv_array(m2, "f32"))))
  invisible(as_array(k_gpu(nv_array(m1, "f32"), nv_array(m2, "f32"))))
  t_cpu <- system.time(for (i in 1:10)
    invisible(as_array(k_cpu(nv_array(m1, "f32"), nv_array(m2, "f32")))))["elapsed"]
  t_gpu <- system.time(for (i in 1:10)
    invisible(as_array(k_gpu(nv_array(m1, "f32"), nv_array(m2, "f32")))))["elapsed"]
  cat(sprintf("2048^2 map incl. transfers: cpu %.1f ms, cuda %.1f ms per call\n",
              t_cpu * 100, t_gpu * 100))
}

# -- (b) mirai daemon ------------------------------------------------------
library(mirai)
daemons(1)
task <- mirai(
  {
    library(anvl)
    f <- jit(function(x) {
      xpad <- nv_pad(x, nv_scalar(0, "f32"),
                     edge_padding_low = c(1L, 1L), edge_padding_high = c(1L, 1L))
      acc <- NULL
      for (dy in -1:1) for (dx in -1:1) {
        sh <- nv_static_slice(xpad, c(2L + dy, 2L + dx),
                              c(n + 1L + dy, n + 1L + dx), c(1L, 1L))
        acc <- if (is.null(acc)) sh else acc + sh
      }
      acc / 9
    })
    as_array(f(nv_array(chunk, "f32")))
  },
  chunk = matrix(runif(256 * 256), 256, 256),
  n = 256L
)
res <- task[]
daemons(0)
ok <- is.matrix(res) && all(dim(res) == c(256, 256)) && !anyNA(res)
cat("mirai daemon chunk task:", if (ok) "OK" else paste("FAILED:", paste(class(res), collapse = ",")), "\n")
if (!ok) print(res)
cat("DONE\n")
