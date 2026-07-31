# Spike B (micro): MLP-shaped compute throughput by pool topology.
# Workload approximates the SI predict kernel: h = relu(W1 %*% x); y = W2 %*% h
# with W1 (64 x 145), W2 (1 x 64), x (145 x 262144)  [512x512 px window].
# Input is uploaded once per daemon; each task is one full forward pass +
# download, so the measurement is XLA compute + download throughput.
# Usage: Rscript spike_b_topology.R <n_daemons> <k|0> <n_windows>
suppressMessages(library(mirai))
args <- commandArgs(trailingOnly = TRUE)
n <- as.integer(args[[1]]); k <- as.integer(args[[2]])
W <- as.integer(args[[3]])

daemons(n)
pids <- vapply(everywhere(Sys.getpid()), function(m) m[], integer(1))
if (k > 0L) {
  cores <- parallel::detectCores()
  for (i in seq_along(pids)) {
    lo <- ((i - 1L) * k) %% cores
    lst <- paste(seq(lo, lo + k - 1L) %% cores, collapse = ",")
    system2("taskset", c("-a", "-cp", lst, pids[[i]]), stdout = FALSE)
  }
}
setup <- function() {
  suppressMessages(library(garry))
  npx <- 512L * 512L
  w1 <- matrix(runif(64 * 145), 64)
  w2 <- matrix(runif(1 * 64), 1)
  .SPIKE_JF <<- garry:::g_jit(function(ins) {
    h <- w1 %*% ins[[1L]]
    h <- (h + abs(h)) / 2
    w2 %*% h
  })
  .SPIKE_X <<- garry:::g_upload(matrix(runif(145 * npx), 145), "f32")
  invisible(garry:::g_download(.SPIKE_JF(list(.SPIKE_X))[[1L]]))  # warm
  TRUE
}
invisible(lapply(everywhere(setup(), setup = setup), function(m) m[]))

run1 <- function() {
  invisible(garry:::g_download(.SPIKE_JF(list(.SPIKE_X))[[1L]]))
  TRUE
}
t0 <- Sys.time()
hs <- lapply(seq_len(W), function(i) mirai(run1(), run1 = run1))
ok <- vapply(hs, function(h) isTRUE(h[]), logical(1))
el <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
cat(sprintf("topology n=%d k=%s: %d/%d windows in %.2fs  (%.2f win/s)\n",
            n, if (k > 0) k else "uncapped", sum(ok), W, el, sum(ok) / el))
daemons(0L)
