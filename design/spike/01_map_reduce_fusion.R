# Spike 01: composed map + reduce in a single jit() call.
# Question: can a multi-op elementwise pipeline ending in a reduction be
# traced and compiled as one kernel, written with plain R operators?

library(anvl)

npx <- 512L
set.seed(1)
nir <- matrix(runif(npx^2, 0.2, 0.6), npx, npx)
red <- matrix(runif(npx^2, 0.05, 0.3), npx, npx)

# Plain R syntax on traced values: NDVI then a scalar reduction.
ndvi_mean <- function(nir, red) {
  ndvi <- (nir - red) / (nir + red)
  scaled <- ndvi * 2 - 0.1          # arbitrary extra map stage
  nv_reduce_mean <- mean            # base mean, traced
  nv_reduce_mean(scaled)
}

f <- jit(ndvi_mean)
a_nir <- nv_array(nir, "f32")
a_red <- nv_array(red, "f32")

got <- as_array(f(a_nir, a_red))
want <- mean(((nir - red) / (nir + red)) * 2 - 0.1)

cat("jit result: ", format(got, digits = 10), "\n")
cat("R reference:", format(want, digits = 10), "\n")
cat("abs diff:   ", format(abs(got - want)), "\n")
stopifnot(abs(got - want) < 1e-5)  # f32 tolerance

# Also: map-only pipeline returning a full array (the FusedNode shape).
ndvi_map <- function(nir, red) (nir - red) / (nir + red)
g <- jit(ndvi_map)
arr <- as_array(g(a_nir, a_red))
stopifnot(max(abs(arr - (nir - red) / (nir + red))) < 1e-6)

cat("PASS: composed map+reduce traces and compiles as one jit kernel\n")
