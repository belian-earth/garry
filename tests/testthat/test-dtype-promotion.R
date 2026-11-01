# The dtype a plan declares is the dtype its kernels compute, so written
# files hold what collect() returns. Integer sources are the risky case:
# float arithmetic and wide sums leave the integer range.

.int_source <- function(dtype = "UInt16", vals = as.numeric(1:600)) {
  f <- withr::local_tempfile(fileext = ".tif", .local_envir = parent.frame())
  ds <- gdalraster::create("GTiff", f, 30, 20, 1, dtype, return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 200, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, 30, 20, vals)
  ds$close()
  f
}

test_that("a double scalar makes an integer raster f32; an integer keeps it", {
  x <- lazy_source(.int_source())
  expect_identical(x@grid@dtype, "u16")
  expect_identical((x * 0.5)@grid@dtype, "f32")
  expect_identical((x - 100)@grid@dtype, "f32")
  expect_identical((x * 2L)@grid@dtype, "u16")
  expect_identical(sqrt(x)@grid@dtype, "f32")
})

test_that("write_tif of float arithmetic on an integer source equals collect", {
  x <- lazy_source(.int_source())
  y <- x * 0.5 - 100
  path <- withr::local_tempfile(fileext = ".tif")
  write_tif(y, path)
  got <- gdal_read_window(path, 1L, 0L, 0L, 30L, 20L)
  expect_equal(got, collect(y), ignore_attr = TRUE, tolerance = 1e-6)
})

test_that("an 8-bit sum over many slices does not wrap", {
  x <- lazy_source(.int_source("Byte", rep(200, 600)))
  s <- reduce_over(lazy_stack(rep(list(x), 3)), "sum", "t")
  expect_identical(s@grid@dtype, "i32")
  expect_true(all(collect(s) == 600))
})

test_that("an 8-bit mean over many slices does not wrap", {
  x <- lazy_source(.int_source("Byte", rep(200, 600)))
  m <- reduce_over(lazy_stack(rep(list(x), 3)), "mean", "t")
  expect_identical(m@grid@dtype, "f32")
  expect_true(all(collect(m) == 200))
})

test_that("g_mean of traced integers averages at f32", {
  f <- anvl::jit(function(x) g_mean(x, dims = 1L))
  x <- anvl::nv_array(array(c(100L, 120L, -128L, 127L), c(2, 2)), dtype = "i8")
  expect_equal(as.vector(anvl::as_array(f(x))), c(110, -0.5))
})

test_that("a map computes the dtype it declares", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  m <- function(v) matrix(v, 20L, 30L)
  expect_plan(lazy_map(x, fn = function(v) v / 2), m(1.5), "f32", file = FALSE)
  expect_plan(lazy_map(x, fn = function(v) v + 1L), m(4), "i16", file = FALSE)
  expect_plan(lazy_map(x, fn = function(v) g_cast(v, "f64")), m(3), "f64", file = FALSE)
  # a carrier is the declared dtype, and a logical stores 0/1 at it
  u <- lazy_source(.int_source("UInt16", rep(3, 600)))
  expect_plan(lazy_map(u, fn = function(v) v + 1L), m(4), "u16", file = FALSE)
  expect_plan(lazy_map(u, fn = function(v) v > 1L), m(1), "u16", file = FALSE)
  # a stack's kernel sees its outer axis
  s <- lazy_stack(rep(list(x), 3), along = "t")
  expect_plan(lazy_map(s, fn = function(v) g_slice_t(v, 1L, 2L) / 2),
              array(1.5, c(20L, 30L, 2L)), "f32", file = FALSE)
})

test_that("a scan and a custom reducer compute the dtype they declare", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  s <- lazy_stack(rep(list(x), 3), along = "t")
  cube <- function(v) array(v, c(20L, 30L, 3L))
  expect_plan(scan_over(s, function(xs, margin) xs[[1L]] / 2), cube(1.5), "f32", file = FALSE)
  expect_plan(scan_over(s, function(xs, margin) xs[[1L]]), cube(3), "i16", file = FALSE)
  expect_plan(reduce_over(s, function(v, dims) g_mean(v, dims), "t"), matrix(3, 20L, 30L), "f32",
              file = FALSE)
  expect_plan(reduce_over(s, function(v, dims) g_max(v, dims), "t"), matrix(3, 20L, 30L), "i16",
              file = FALSE)
})

test_that("one fn over many same-shaped inputs traces once", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  y <- lazy_source(.int_source("Int16", rep(4, 600)))
  # A closure's captures are part of its identity, so a trace counts itself
  # with a message rather than a captured counter.
  traces <- function(code) length(testthat::capture_messages(code))
  fn <- function(v) {
    message("traced")
    v * 2L
  }
  expect_identical(traces({
    a <- lazy_map(x, fn = fn)
    b <- lazy_map(y, fn = fn)
  }), 1L)
  expect_identical(b@grid@dtype, a@grid@dtype)
  # a reducer differs by the dim it reduces
  s <- lazy_stack(list(x, y), along = "t")
  rd <- function(v, dims) {
    message("traced")
    g_mean(v, dims)
  }
  expect_identical(traces(r1 <- reduce_over(s, rd, "t")), 1L)
  expect_identical(traces(r2 <- reduce_over(lazy_stack(list(y, x), along = "t"), rd, "t")), 0L)
  expect_identical(r2@grid@dtype, r1@grid@dtype)
  # another input dtype traces again
  u <- lazy_source(.int_source("UInt16", rep(3, 600)))
  expect_identical(traces(lazy_map(u, fn = fn)), 1L)
})

test_that("a fn that cannot trace fails where the raster is built", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  err <- expect_error(lazy_map(x, fn = function(v) stop("no such band")),
                      class = "garry_kernel_error")
  expect_match(conditionMessage(err), "no such band")
  expect_match(conditionMessage(err), "dtype")
  expect_identical(lazy_map(x, fn = function(v) stop("later"), dtype = "f32")@grid@dtype, "f32")
})

test_that("a scalar an integer array cannot hold fails where it meets it", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  for (fn in list(
    function(v) g_ifelse(v > 1L, 0.5, v),
    function(v) g_ifelse(v > 1L, v, NaN),
    function(v) g_pad(v, 1L, 0.5)
  )) {
    err <- expect_error(lazy_map(x, fn = fn), class = "garry_kernel_error")
    expect_match(conditionMessage(err), "g_cast")
  }
  expect_identical(
    lazy_map(x, fn = function(v) g_ifelse(v > 1L, 7, v))@grid@dtype,
    "i16"
  )
})

.int_tile <- function(type, vals, x0, nx = 10L, ny = 10L, epsg = "EPSG:32632") {
  f <- withr::local_tempfile(fileext = ".tif", .local_envir = parent.frame())
  ds <- gdalraster::create("GTiff", f, nx, ny, 1L, type, return_obj = TRUE)
  ds$setGeoTransform(c(x0, 10, 0, 100, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt(epsg))
  ds$write(1L, 0L, 0L, nx, ny, rep(vals, length.out = nx * ny))
  ds$close()
  f
}

test_that("a tile set with holes refuses an integer kernel", {
  a <- .int_tile("Int16", 3, 0)
  b <- .int_tile("Int16", 5, 200)
  g <- grid_spec("EPSG:32632", extent = c(0, 0, 300, 100),
                 dims = c(x = 30L, y = 10L), dtype = "i16")
  x <- lazy_source(c(a, b), grid = g)
  expect_identical(x@grid@dtype, "i16")
  expect_error(collect(x + 1L, distributed = FALSE), class = "garry_nodata_error")
  # with a sentinel it reads as float and the hole is NaN
  y <- lazy_source(c(a, b), grid = g, nodata = -999)
  got <- collect(y + 1, distributed = FALSE)
  expect_true(all(is.nan(got[, 11:20])))
  expect_true(all(got[, 1:10] == 4) && all(got[, 21:30] == 6))
})

test_that("focal windows see NaN past the edge, whatever they sit on", {
  mean_fn <- function(sh) Reduce(`+`, sh) / length(sh)
  x <- lazy_source(.int_source("Int16", rep(10, 600)))
  edge <- function(r) {
    m <- collect(r, distributed = FALSE)
    d <- dim(m)
    all(is.nan(m[c(1L, d[[1L]]), ])) && all(is.nan(m[, c(1L, d[[2L]])])) &&
      all(m[2:(d[[1L]] - 1L), 2:(d[[2L]] - 1L)] == m[2L, 2L])
  }
  expect_true(edge(focal_map(x, mean_fn, 1L)))
  expect_true(edge(focal_map(x * 0.5, mean_fn, 1L)))
  expect_true(edge(focal_map(lazy_map(x, fn = function(v) v / 2), mean_fn, 1L)))
  expect_true(edge(focal_map(align_to(x, grid_spec(
    grid_crs(x), extent = grid_bbox(x), dims = c(x = 15L, y = 10L)
  )), mean_fn, 1L)))
  stk <- lazy_stack(list(a = x, b = x), along = "t")
  expect_true(edge(focal_map(reduce_over(stk, "max", "t"), mean_fn, 1L)))
  # the copies are shared, and the integer raster is untouched
  n <- length(graph_ids(x@graph))
  focal_map(x, mean_fn, 1L)
  focal_map(x, mean_fn, 1L)
  expect_identical(length(graph_ids(x@graph)), n + 2L)
  expect_true(all(collect(x, distributed = FALSE) == 10))
})

test_that("a kernel that names its float dtype keeps its integer read", {
  x <- lazy_source(.int_source("Int16", rep(c(1, 2), 300)))
  bits <- lazy_map(x, fn = function(v) g_cast(g_bitand(v, 1L), "f32"), dtype = "f32")
  mean_fn <- function(sh) Reduce(`+`, sh) / length(sh)
  r <- collect(focal_map(bits, mean_fn, 1L), distributed = FALSE)
  # the low bit of 1, 2, 1, 2 ... in every row; the ring past the raster is an
  # integer read's, so 0, and the windows there count it: 3 x 3 sums over 9
  pad <- matrix(0, 22L, 32L)
  pad[2:21, 2:31] <- matrix(rep(c(1, 0), 15L), 20L, 30L, byrow = TRUE)
  want <- matrix(0, 20L, 30L)
  for (dy in 0:2) for (dx in 0:2) {
    want <- want + pad[(1 + dy):(20 + dy), (1 + dx):(30 + dx)]
  }
  .expect_cells(unclass(r), want / 9, tolerance = 1e-6)
})

test_that("arithmetic on an integer raster keeps the edge NaN under a window", {
  mean_fn <- function(sh) Reduce(`+`, sh) / length(sh)
  x <- lazy_source(.int_source("Int16", rep(9, 600)))
  for (y in list(sqrt(x), round(x, 1L), !x)) {
    m <- collect(focal_map(y, mean_fn, 1L), distributed = FALSE)
    expect_true(all(is.nan(m[1L, ])) && all(is.nan(m[, 30L])))
    expect_false(anyNA(m[2:19, 2:29]))
  }
})

test_that("shrink_footprint keeps its edge over an integer raster", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  m <- collect(shrink_footprint(x, 1L, boundary = "keep"), distributed = FALSE)
  expect_true(all(m == 3))
})

test_that("Math on an integer dataset declares f32 per band", {
  x <- lazy_source(.int_source())
  ds <- as_dataset(list(a = x, b = x * 0.5))
  r <- sqrt(ds)
  expect_identical(r$a@grid@dtype, "f32")
  expect_identical(r$b@grid@dtype, "f32")
  expect_equal(collect(r$a), sqrt(collect(x)), tolerance = 1e-6, ignore_attr = TRUE)
})
