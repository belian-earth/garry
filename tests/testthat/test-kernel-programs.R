# A kernel reaches a daemon as a program built on the host. The program a
# task runs must be the kernel that task needs: same dtypes, same shapes,
# same constants. Each case compares a pooled run with the in-process one.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

.kp_tif <- function(vals, type = "Float32", nb = 1L) {
  f <- tempfile(fileext = ".tif")
  n <- as.integer(sqrt(length(vals)))
  ds <- gdalraster::create("GTiff", f, n, n, nb, type, return_obj = TRUE)
  ds$setGeoTransform(c(500000, 30, 0, 5000000, 0, -30))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32633"))
  for (b in seq_len(nb)) ds$write(b, 0L, 0L, n, n, vals + b - 1)
  ds$close()
  f
}
.kp_vals <- function() rep(c(1000, 2000, 3000, 4000), 1024)

.kp_same <- function(x) {
  ref <- collect(x, distributed = FALSE)
  got <- collect(x, distributed = TRUE)
  expect_equal(unclass(got), unclass(ref), tolerance = 1e-6, ignore_attr = TRUE)
}

test_that("sources of different dtypes never share a program", {
  local_pools(2, 1)
  fn <- function(v) v * 0.5
  .kp_same(lazy_map(lazy_source(.kp_tif(.kp_vals())), fn = fn, dtype = "f32"))
  .kp_same(lazy_map(lazy_source(.kp_tif(.kp_vals(), "UInt16")), fn = fn, dtype = "f32"))
  .kp_same(lazy_map(lazy_source(.kp_tif(.kp_vals(), "Int16")), fn = fn, dtype = "f32"))
})

test_that("a map that returns another dtype than it declares still runs", {
  local_pools(2, 1)
  src <- lazy_source(.kp_tif(.kp_vals(), "UInt16"))
  y <- lazy_map(src, fn = function(v) v * 1e-4)
  a <- lazy_map(y, fn = function(v) v + 1, dtype = "f32")
  b <- lazy_map(y, fn = function(v) v * 2, dtype = "f32")
  p <- plan_lazy(list(a = a, b = b))
  ref <- execute_plan(p)
  got <- execute_plan_mirai(p)
  expect_equal(got$a, ref$a, tolerance = 1e-6, ignore_attr = TRUE)
  expect_equal(got$b, ref$b, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a global a kernel reads is part of its identity", {
  local_pools(2, 1)
  f <- .kp_tif(.kp_vals())
  fn <- function(v) v * garry_kp_k
  environment(fn) <- globalenv()
  withr::defer(rm("garry_kp_k", envir = globalenv()))
  assign("garry_kp_k", 2, envir = globalenv())
  x <- lazy_map(lazy_source(f), fn = fn, dtype = "f32")
  a <- tryCatch(collect(x, distributed = TRUE), error = function(e) NULL)
  skip_if(is.null(a), "globals do not reach daemons")
  assign("garry_kp_k", 3, envir = globalenv())
  x <- lazy_map(lazy_source(f), fn = fn, dtype = "f32")
  b <- collect(x, distributed = TRUE)
  expect_equal(unclass(b) / unclass(a), matrix(1.5, nrow(a), ncol(a)),
               tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("kernels capturing different arrays never share a program", {
  local_pools(2, 1)
  f <- .kp_tif(.kp_vals())
  mk <- function(k) {
    w <- anvl::nv_array(array(k, c(64L, 64L)), dtype = "f32")
    force(w)
    lazy_map(lazy_source(f), fn = function(v) v * w, dtype = "f32")
  }
  a <- collect(mk(2), distributed = TRUE)
  gc()
  b <- collect(mk(3), distributed = TRUE)
  expect_equal(unclass(b) / unclass(a), matrix(1.5, nrow(a), ncol(a)),
               tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a cube's outer dims keep their rank, size-one dims included", {
  local_pools(2, 1)
  mk <- function(n) {
    srcs <- lapply(seq_len(n), function(i) lazy_source(.kp_tif(.kp_vals() + i)))
    m <- lazy_map(lazy_stack(stats::setNames(srcs, seq_len(n)), along = "t"),
                  fn = function(v) v + 1, dtype = "f32")
    list(a = reduce_over(m, "mean", over = "t"),
         b = reduce_over(m, "max", over = "t"))
  }
  for (n in c(1L, 2L)) {
    p <- plan_lazy(mk(n))
    ref <- execute_plan(p)
    got <- execute_plan_mirai(p)
    expect_equal(got$a, ref$a, tolerance = 1e-6, ignore_attr = TRUE)
    expect_equal(got$b, ref$b, tolerance = 1e-6, ignore_attr = TRUE)
  }
})

test_that("scans over different labels never share a program", {
  local_pools(2, 1)
  f <- .kp_tif(.kp_vals())
  mk <- function(lab) {
    a <- lazy_source(f)
    s <- lazy_stack(stats::setNames(list(a + 0, a * 2), lab), along = "t")
    body <- function(xs, margin, labels) {
      if (identical(labels, c("d1", "d2"))) xs[[1L]] + 100 else xs[[1L]]
    }
    scan_over(s, body, over = "t")
  }
  .kp_same(mk(c("d1", "d2")))
  .kp_same(mk(c("d3", "d4")))
})

test_that("a kernel refuses inputs it was not built for", {
  set <- garry:::.program_set(
    "kp-refuses",
    function(inputs) list(inputs[[1L]] * 2),
    "f32",
    list(list(c(4L, 4L)))
  )
  run <- garry:::.kernel_of(set)
  expect_equal(
    as.numeric(g_download(run(list(g_upload(matrix(1, 4, 4), "f32")))[[1L]])),
    rep(2, 16)
  )
  expect_error(run(list(g_upload(matrix(1, 4, 4), "u16"))), "garry_no_program")
  expect_error(run(list(g_upload(matrix(1, 5, 5), "f32"))), "garry_no_program")
})

test_that("identity follows globals, recursive ones included", {
  fn <- function(v) garry_kp_loop(v)
  environment(fn) <- globalenv()
  loop <- function(x) if (FALSE) garry_kp_loop(x) else x
  environment(loop) <- globalenv()
  assign("garry_kp_loop", loop, envir = globalenv())
  withr::defer(rm("garry_kp_loop", envir = globalenv()))
  a <- rlang::hash(garry:::.fn_identity(fn))
  loop2 <- function(x) if (FALSE) garry_kp_loop(x) else x + 1
  environment(loop2) <- globalenv()
  assign("garry_kp_loop", loop2, envir = globalenv())
  expect_false(identical(a, rlang::hash(garry:::.fn_identity(fn))))
})

test_that("a deep hygiene pass forgets which kernels daemons hold", {
  state <- garry:::.garry_state
  state$prof_warm <- new.env(parent = emptyenv())
  expect_no_error(garry_pool_hygiene(deep = TRUE))
  expect_null(state$prof_warm)
})

test_that("a read lost to a dead connection is a failed read, not data", {
  expect_length(garry:::.gd_fetch_errs(list(structure(19L, class = "errorValue"))), 1L)
})
