# Extracted from test-grad-convergence.R:33

# setup ------------------------------------------------------------------------
library(testthat)
test_env <- simulate_test_env(package = "garry", path = "..")
attach(test_env, warn.conflicts = FALSE)

# prequel ----------------------------------------------------------------------
skip_if_not_installed("anvl")

# test -------------------------------------------------------------------------
fx <- fixture_random_f32()
k_true <- matrix(c(0.05, 0.1, 0.05,
                     0.10, 0.4, 0.10,
                     0.05, 0.1, 0.05), 3, 3, byrow = TRUE)
a0 <- lazy_source(fx)
y_path <- tempfile(fileext = ".tif")
collect(focal_kernel(a0, k_true), path = y_path)
build_loss <- function() {
    a <- lazy_source(fx)
    y <- lazy_source(y_path, graph = a@graph)
    fk <- focal_kernel(a, matrix(1 / 9, 3, 3))
    d <- fk - y
    list(loss = reduce_over(d * d, "mean", c("x", "y")), fk = fk)
  }
lp <- build_loss()
k_est <- matrix(1 / 9, 3, 3)
lr <- 0.2
losses <- numeric(0)
for (step in 1:300) {
    r <- lazy_value_and_grad(lp$loss, lp$fk, weights = k_est)
    k_est <- k_est - lr * r$grad
    losses <- c(losses, r$value)
  }
