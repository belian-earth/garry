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

test_that("a float map over integers feeds the stages after it", {
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
  # a closure resolves its globals on the daemon, where this one is absent
  skip_if(identical(garry_opt("kernel_wire"), "closure"), "globals do not reach daemons")
  a <- collect(x, distributed = TRUE)
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

test_that("a fused integer kernel comes back as integers", {
  local_pools(2, 1)
  for (ty in c("UInt16", "Int16", "Int32")) {
    .kp_same(lazy_map(lazy_source(.kp_tif(.kp_vals(), ty)), fn = function(v) v + 1L))
  }
})

test_that("a declared dtype holds inside a stage as it does across one", {
  a <- lazy_map(lazy_source(.kp_tif(rep(5, 4096))), fn = function(v) v / 3, dtype = "i16")
  expect_equal(unique(as.vector(collect(a * 2L, distributed = FALSE))), 2)
})

test_that("a logical map feeds a select in the next map", {
  a <- lazy_map(lazy_source(.kp_tif(rep(5, 4096))), fn = function(v) v > 0)
  b <- lazy_map(a, fn = function(m) g_ifelse(m, 2, 3))
  expect_equal(unique(as.vector(collect(b, distributed = FALSE))), 2)
})

test_that("arrays held in a classed list or an environment are identity", {
  arr <- function(k) anvl::nv_array(array(k, c(64L, 64L)), dtype = "f32")
  in_list <- function(k) {
    m <- structure(list(w = arr(k)), class = "garry_kp_model")
    function(v) v * m$w
  }
  in_env <- function(k) {
    e <- new.env()
    e$w <- arr(k)
    e$self <- e
    function(v) v * e$w
  }
  # an array's handle hashes alike across collections of its buffer, so
  # only its content can tell two apart
  for (mk in list(in_list, in_env)) {
    ids <- vapply(1:6, function(k) {
      id <- rlang::hash(garry:::.fn_identity(mk(k)))
      gc()
      id
    }, character(1))
    expect_equal(anyDuplicated(ids), 0L)
    expect_identical(ids[[3L]], rlang::hash(garry:::.fn_identity(mk(3))))
  }
})

test_that("a kernel that calls itself has an identity", {
  mk <- function(k) {
    f <- function(v, n) if (n == 0) v + k else f(v + 1, n - 1)
    function(v) f(v, 3)
  }
  expect_identical(
    rlang::hash(garry:::.fn_identity(mk(1))),
    rlang::hash(garry:::.fn_identity(mk(1)))
  )
  expect_false(identical(
    rlang::hash(garry:::.fn_identity(mk(1))),
    rlang::hash(garry:::.fn_identity(mk(2)))
  ))
  x <- lazy_map(lazy_source(.kp_tif(rep(5, 4096))), fn = mk(1), dtype = "f32")
  expect_equal(unique(as.vector(collect(x, distributed = FALSE))), 9)
})

test_that("identity holds what a kernel reads from the session, not all it could", {
  bare <- function(v) v
  expect_length(garry:::.fn_identity(bare)$globals, 0L)
  on_global <- function(v) v * garry_kp_scale
  environment(on_global) <- globalenv()
  assign("garry_kp_scale", 2, envir = globalenv())
  assign("garry_kp_dt", 1, envir = globalenv())
  withr::defer(rm("garry_kp_scale", "garry_kp_dt", envir = globalenv()))
  mk <- function() {
    garry_kp_dt <- "f32"
    function(v) g_cast(v, garry_kp_dt)
  }
  captured <- mk()
  a <- rlang::hash(garry:::.fn_identity(captured))
  assign("garry_kp_dt", 2, envir = globalenv())
  expect_identical(rlang::hash(garry:::.fn_identity(captured)), a)
  # a name a namespace resolves before the session does
  ns_fn <- function(v) g_max(v, 1L)
  environment(ns_fn) <- new.env(parent = asNamespace("garry"))
  b <- rlang::hash(garry:::.fn_identity(ns_fn))
  assign("g_max", function(...) 1, envir = globalenv())
  withr::defer(rm("g_max", envir = globalenv()))
  expect_identical(rlang::hash(garry:::.fn_identity(ns_fn)), b)
  # and a global it really reads still counts
  g <- rlang::hash(garry:::.fn_identity(on_global))
  assign("garry_kp_scale", 3, envir = globalenv())
  expect_false(identical(rlang::hash(garry:::.fn_identity(on_global)), g))
})

test_that("a kernel with very many inputs stays addressable", {
  n <- 1500L
  sets <- list(rep(list(c(8L, 8L)), n))
  dtypes <- rep("f32", n)
  tag <- garry:::.program_tag(dtypes, sets)
  expect_lt(nchar(tag), 100L)
  set <- garry:::.program_set(
    paste0("kp-wide", tag),
    function(inputs) list(inputs[[1L]] * 2),
    dtypes,
    sets
  )
  run <- garry:::.kernel_of(set)
  x <- g_upload(matrix(1, 8, 8), "f32")
  expect_equal(as.numeric(g_download(run(rep(list(x), n))[[1L]])), rep(2, 64))
})

test_that("an integer stage's edge ring holds 0, not NaN, at every width", {
  f <- .kp_tif(rep(5, 4096))
  for (dt in c("i64", "u32", "i32")) {
    g <- graph_new()
    maps <- lapply(1:2, function(b) {
      lazy_map(lazy_source(f, graph = g), fn = function(x) g_cast(x, dt))
    })
    b <- lazy_map(
      lazy_stack(maps, along = "band"),
      fn = function(v) g_cast(v, "f32"),
      dtype = "f32"
    )
    x <- focal_map(b, radius = 1L, fn = function(sh) Reduce(`+`, sh))
    v <- collect(x, distributed = FALSE)
    expect_equal(range(v), c(20, 45))
  }
})

test_that("a set holds each constant once, and a kernel drops its R copy", {
  w <- anvl::nv_array(rep(1, 8L), dtype = "f32")
  u <- anvl::nv_array(rep(2, 8L), dtype = "f32")
  fn <- function(inputs) list(inputs[[1L]] + g_sum(w) + g_sum(u))
  set <- garry:::.program_set(
    "kp-constants", fn, "f32", list(list(c(4L, 4L)), list(c(4L, 8L)))
  )
  expect_length(attr(set, "constants"), 2L)
  run <- garry:::.kernel_of(set)
  a <- run(list(g_upload(matrix(1, 4, 4), "f32")))
  b <- run(list(g_upload(matrix(1, 4, 8), "f32")))
  expect_equal(as.numeric(g_download(a[[1L]])), rep(25, 16))
  expect_equal(as.numeric(g_download(b[[1L]])), rep(25, 32))
  e <- environment(run)
  expect_length(Filter(Negate(is.null), e$pool), 0L)
})

test_that("constants made while tracing cross as bytes, whatever their dtype", {
  fn <- function(inputs) {
    k <- anvl::nv_array(c(1, 2, 3, 4), dtype = "f32")
    m <- anvl::nv_array(c(TRUE, FALSE, TRUE, TRUE), dtype = "bool")
    i <- anvl::nv_array(1:4, dtype = "i32")
    list(g_ifelse(m, k, 0) + g_cast(i, "f32") + inputs[[1L]])
  }
  set <- garry:::.program_set("kp-plain", fn, "f32", list(list(4L)))
  run <- garry:::.kernel_of(set)
  got <- run(list(g_upload(c(10, 10, 10, 10), "f32")))[[1L]]
  expect_equal(as.numeric(g_download(got)), c(12, 12, 16, 18))
})

test_that("warming a kernel compiles its first shape alone", {
  set <- garry:::.program_set(
    "kp-warm", function(inputs) list(inputs[[1L]] * 2), "f32",
    list(list(c(4L, 4L)), list(c(4L, 8L)), list(c(8L, 4L)))
  )
  run <- garry:::.kernel_of(set)
  attr(run, "warm")()
  expect_equal(sum(!vapply(environment(run)$compiled, is.null, logical(1))), 1L)
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
  err <- expect_error(run(list(g_upload(matrix(1, 4, 4), "u16"))), class = "garry_no_program_error")
  expect_match(conditionMessage(err), "i32:4x4", fixed = TRUE)
  expect_match(conditionMessage(err), "garry.kernel_wire", fixed = TRUE)
  expect_error(run(list(g_upload(matrix(1, 5, 5), "f32"))), class = "garry_no_program_error")
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
  expect_error(
    garry:::.gd_check_fetch(list(structure(19L, class = "errorValue")), "source"),
    "daemon exited"
  )
})
