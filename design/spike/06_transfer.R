# Spike 06: ingress/egress cost and per-call dispatch overhead.
# The executor moves ~10-100 MB chunks between R and AnvlArray constantly;
# this must not dominate compute.

library(anvl)

sizes <- c(256L, 512L, 1024L, 2048L)
cat(sprintf("%8s %6s %14s %14s %14s\n",
            "size", "dtype", "ingress MB/s", "egress MB/s", "roundtrip ms"))
for (s in sizes) {
  for (dt in c("f32", "f64")) {
    m <- matrix(runif(s * s), s, s)
    bytes <- s * s * ifelse(dt == "f32", 4, 8)
    reps <- max(3L, as.integer(2e8 / bytes))
    t_in <- system.time(for (i in seq_len(reps)) a <- nv_array(m, dt))["elapsed"]
    a <- nv_array(m, dt)
    t_out <- system.time(for (i in seq_len(reps)) invisible(as_array(a)))["elapsed"]
    cat(sprintf("%8d %6s %14.0f %14.0f %14.2f\n",
                s, dt,
                bytes * reps / t_in / 2^20,
                bytes * reps / t_out / 2^20,
                (t_in + t_out) / reps * 1000))
  }
}

# Per-call dispatch overhead: trivial pre-compiled kernel, small input.
f <- jit(function(x) x + 1)
small <- nv_array(matrix(1, 8, 8), "f32")
invisible(f(small))  # compile
n <- 2000L
t <- system.time(for (i in seq_len(n)) invisible(f(small)))["elapsed"]
cat(sprintf("\nper-call dispatch overhead (cached kernel, 8x8): %.1f us\n", t / n * 1e6))

# Realistic chunk kernel throughput: NDVI + rescale on 1024^2 f32,
# including transfers, vs vectorized base R.
s <- 1024L
nir <- matrix(runif(s * s, 0.2, 0.6), s, s)
red <- matrix(runif(s * s, 0.05, 0.3), s, s)
k <- jit(function(a, b) ((a - b) / (a + b)) * 2 - 0.1)
invisible(as_array(k(nv_array(nir, "f32"), nv_array(red, "f32"))))  # compile
t_full <- system.time(for (i in 1:20)
  invisible(as_array(k(nv_array(nir, "f32"), nv_array(red, "f32")))))["elapsed"] / 20
t_r <- system.time(for (i in 1:20)
  invisible(((nir - red) / (nir + red)) * 2 - 0.1))["elapsed"] / 20
cat(sprintf("1024^2 NDVI incl. transfers: jit %.1f ms, base R %.1f ms\n",
            t_full * 1000, t_r * 1000))
cat("DONE (numbers above feed the design note)\n")
