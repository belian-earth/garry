# Spike 07: shape-triggered recompilation.
# XLA compiles per (shape, dtype). Edge chunks with ragged sizes would
# each trigger a fresh compile. Measure compile cost vs cached dispatch to
# decide between ragged chunks and pad-to-uniform.

library(anvl)

f <- jit(function(a, b) ((a - b) / (a + b)) * 2 - 0.1)

time_call <- function(nr, nc) {
  a <- nv_array(matrix(runif(nr * nc), nr, nc), "f32")
  b <- nv_array(matrix(runif(nr * nc), nr, nc), "f32")
  first <- unname(system.time(invisible(as_array(f(a, b))))["elapsed"])
  again <- unname(system.time(for (i in 1:5) invisible(as_array(f(a, b))))["elapsed"]) / 5
  c(first = first * 1000, cached = again * 1000)
}

cat(sprintf("%12s %18s %18s\n", "shape", "first call ms", "cached call ms"))
shapes <- list(c(512L, 512L), c(512L, 512L),   # repeat: must hit cache
               c(512L, 400L), c(511L, 512L),   # ragged edges: recompile
               c(1024L, 1024L))
for (sh in shapes) {
  r <- time_call(sh[1], sh[2])
  cat(sprintf("%12s %18.1f %18.2f\n",
              paste(sh, collapse = "x"), r["first"], r["cached"]))
}

cat("\nInterpretation: 'first call' minus 'cached' approximates compile+trace\n")
cat("cost paid per novel shape. If large relative to per-chunk compute, the\n")
cat("planner must pad edge chunks to the uniform chunk shape.\n")
