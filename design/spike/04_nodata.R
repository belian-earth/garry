# Spike 04: nodata semantics.
# Hypothesis: NaN-as-nodata for float pipelines, with nan_rm = TRUE on
# reductions, reproduces R's na.rm = TRUE semantics. Also: valid-count and
# all-nodata cells.

library(anvl)

nt <- 7L; npx <- 64L
set.seed(4)
stack_r <- array(runif(nt * npx^2), dim = c(nt, npx, npx))
# Knock out ~30% of observations, plus one pixel missing in ALL time steps.
stack_r[sample(length(stack_r), length(stack_r) * 0.3)] <- NaN
stack_r[, 5, 7] <- NaN

a <- nv_array(stack_r, "f32")

# Temporal mean ignoring nodata (the composite workhorse).
tmean <- jit(function(x) nv_mean(x, dims = 1L, nan_rm = TRUE))
got <- as_array(tmean(a))
want <- apply(stack_r, c(2, 3), function(v) mean(v, na.rm = TRUE))  # NaN where none valid
cat("temporal mean nan_rm: max abs diff (valid cells):",
    max(abs(got[!is.nan(want)] - want[!is.nan(want)])), "\n")
stopifnot(identical(is.nan(got), is.nan(want)))   # all-nodata -> NaN out
stopifnot(max(abs(got[!is.nan(want)] - want[!is.nan(want)])) < 1e-5)

# Median composite: the vrtility flagship.
has_nan_rm <- "nan_rm" %in% names(formals(nv_median))
cat("nv_median has nan_rm:", has_nan_rm, "\n")
if (has_nan_rm) {
  tmed <- jit(function(x) nv_median(x, dim = 1L, nan_rm = TRUE))
  got_m <- as_array(tmed(a))
  want_m <- apply(stack_r, c(2, 3), function(v) median(v, na.rm = TRUE))
  # R returns NA (not NaN) for all-nodata cells; anvl returns NaN. Both are
  # "no value"; compare only finite cells and check the nodata sets agree.
  ok <- is.finite(want_m)
  stopifnot(identical(!is.finite(got_m), !ok))
  cat("temporal median nan_rm: max abs diff:", max(abs(got_m[ok] - want_m[ok])), "\n")
  stopifnot(max(abs(got_m[ok] - want_m[ok])) < 1e-5)
}

# Valid-observation count (needed for quality reporting / min-count rules).
vcount <- jit(function(x) {
  nv_reduce_sum(nv_convert(nv_not(nv_is_nan(x)), "f32"), dims = 1L)
})
got_c <- as_array(vcount(a))
want_c <- apply(stack_r, c(2, 3), function(v) sum(!is.nan(v)))
stopifnot(max(abs(got_c - want_c)) == 0)
cat("valid-count via is_nan + reduce_sum: exact\n")

# NaN poison check WITHOUT nan_rm: confirms default propagation semantics.
tmean_naive <- jit(function(x) nv_mean(x, dims = 1L))
got_n <- as_array(tmean_naive(a))
cat("without nan_rm,", sum(is.nan(got_n)), "of", npx^2, "cells are NaN (expected: most)\n")

# Integer nodata: no NaN in i32; sentinel + ifelse is the pattern.
sent <- jit(function(x, nodata) {
  valid <- nv_ne(x, nodata)
  nv_ifelse(valid, nv_convert(x, "f32"), nv_scalar(NaN, "f32"))
})
xi <- matrix(c(1L, 2L, -9999L, 4L), 2, 2)
got_i <- as_array(sent(nv_array(xi, dtype = "i32"), nv_scalar(-9999L, dtype = "i32")))
stopifnot(is.nan(got_i[1, 2]), got_i[1, 1] == 1)
cat("integer sentinel -> NaN promotion works\n")

cat("PASS: NaN-sentinel nodata model is viable end to end\n")
