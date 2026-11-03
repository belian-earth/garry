# Pipeline gradients vs finite differences of collect()'d losses.


# Each cell of a sweep is two collects at new weights, so two cold kernels.
.fd_all <- as.matrix(expand.grid(1:3, 1:3))
# The (dy, dx) layout is proved over every cell once. Elsewhere these three
# are enough: they see a swap of the axes, and the masks and maps around the
# focal do not depend on which weight moved.
.fd_some <- rbind(c(1L, 2L), c(2L, 1L), c(3L, 3L))

# Central differences of the loss at `cells`, a [row, column] index of k0.
.fd_kernel_grad <- function(build_loss, k0, cells = .fd_some, eps = 1e-2) {
  vapply(seq_len(nrow(cells)), function(n) {
    at <- cells[n, , drop = FALSE]
    kp <- k0; kp[at] <- kp[at] + eps
    km <- k0; km[at] <- km[at] - eps
    (collect(build_loss(kp)) - collect(build_loss(km))) / (2 * eps)
  }, numeric(1))
}

test_that("kernel gradient of mean(focal_kernel(x, k)) matches FD", {
  f <- fixture_gradient_f32()
  # Asymmetric kernel: catches any (dy, dx) layout/transpose slip.
  k0 <- matrix(c(0.05, 0.2, 0.0,
                 0.10, 0.4, 0.05,
                 0.00, 0.1, 0.10), 3, 3, byrow = TRUE)

  build <- function(k) {
    a <- lazy_source(f)
    reduce_over(focal_kernel(a / 1000, k), "mean", c("x", "y"))
  }
  # The focal handle has to come from the loss's own graph.
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000, k0)
  loss <- reduce_over(fk, "mean", c("x", "y"))

  got <- lazy_value_and_grad(loss, fk)
  fd <- .fd_kernel_grad(build, k0, .fd_all)

  expect_equal(got$grad[.fd_all], fd, tolerance = 5e-3)
  expect_equal(got$value, collect(build(k0)), tolerance = 1e-5)
})

test_that("gradient with maps before and after the focal matches FD", {
  f <- fixture_gradient_f32()
  k0 <- matrix(c(0, 0.3, 0,
                 0.2, 0.1, 0.1,
                 0, 0.3, 0), 3, 3, byrow = TRUE)

  build <- function(k) {
    a <- lazy_source(f)
    fk <- focal_kernel(a / 1000 + 1, k)
    reduce_over(fk * 2 - 1, "sum", c("x", "y"))
  }
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000 + 1, k0)
  loss <- reduce_over(fk * 2 - 1, "sum", c("x", "y"))

  got <- lazy_value_and_grad(loss, fk)
  fd <- .fd_kernel_grad(build, k0, eps = 1e-3)

  expect_equal(got$grad[.fd_some] / abs(fd + (fd == 0)),
               fd / abs(fd + (fd == 0)), tolerance = 5e-3)
  expect_equal(got$value, collect(build(k0)), tolerance = 1e-2)
})

test_that("gradients on nodata rasters are poison-free and match FD", {
  f <- fixture_i16_nodata()
  k0 <- matrix(c(0.1, 0.2, 0.05,
                 0.15, 0.3, 0.05,
                 0.05, 0.05, 0.05), 3, 3, byrow = TRUE)
  build <- function(k) {
    a <- lazy_source(f)
    reduce_over(focal_kernel(a / 1000, k), "mean", c("x", "y"))
  }
  a <- lazy_source(f)
  fk <- focal_kernel(a / 1000, k0)
  loss <- reduce_over(fk, "mean", c("x", "y"))

  got <- lazy_value_and_grad(loss, fk)
  expect_false(anyNA(got$grad))
  expect_equal(got$grad[.fd_some], .fd_kernel_grad(build, k0), tolerance = 5e-3)
})

test_that("NaN produced inside the pipeline is skipped, as collect() skips it", {
  f <- fixture_gradient_f32()
  k0 <- matrix(c(0.05, 0.2, 0.0,
                 0.10, 0.4, 0.05,
                 0.00, 0.1, 0.10), 3, 3, byrow = TRUE)
  # a map that gates part of the focal output to nodata, on a condition
  # that does not move with the kernel (so finite differences are valid)
  gate <- function(v, s) g_ifelse(s > 2500, NaN, v)
  build <- function(k) {
    src <- lazy_source(f)
    fk <- focal_kernel(src / 1000, k)
    reduce_over(lazy_map(fk, src, fn = gate, dtype = "f32"), "mean", c("x", "y"))
  }
  src <- lazy_source(f)
  fk <- focal_kernel(src / 1000, k0)
  loss <- reduce_over(lazy_map(fk, src, fn = gate, dtype = "f32"), "mean", c("x", "y"))
  got <- lazy_value_and_grad(loss, fk)
  expect_false(is.nan(got$value))
  expect_equal(got$value, collect(build(k0)), tolerance = 1e-5)
  expect_equal(got$grad[.fd_some], .fd_kernel_grad(build, k0), tolerance = 5e-3)
})

test_that("the gradient path reads a source as collect() does (resampling)", {
  f <- fixture_gradient_f32()
  ext <- c(500000, 4599600, 500600, 4600000)
  coarse <- grid_spec("EPSG:32632", extent = ext, dims = c(20L, 10L), dtype = "f32")
  gti <- withr::local_tempfile(fileext = ".gti.fgb")
  gti_index_create(
    data.frame(location = f, xmin = ext[1], ymin = ext[2], xmax = ext[3], ymax = ext[4]),
    gti, crs = "EPSG:32632"
  )
  src <- lazy_source(
    paste0("GTI:", gti),
    open_options = gti_open_options(coarse),
    grid = coarse,
    resampling = "average"
  )
  k0 <- matrix(c(0, 0.1, 0, 0.1, 0.6, 0.1, 0, 0.1, 0), 3, 3)
  fk <- focal_kernel(src / 1000, k0)
  loss <- reduce_over(fk, "mean", c("x", "y"))
  got <- lazy_value_and_grad(loss, fk)
  expect_equal(got$value, collect(loss), tolerance = 1e-5)
})
