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

.int_square <- function(dtype, value, n = 300L) {
  f <- withr::local_tempfile(fileext = ".tif", .local_envir = parent.frame())
  ds <- gdalraster::create("GTiff", f, n, n, 1, dtype, return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, n * 10, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, n, n, rep(value, n * n))
  ds$close()
  f
}

test_that("a spatial sum and mean of integers do not wrap within a chunk", {
  x <- lazy_source(.int_square("Int16", 30000))
  n <- 300^2
  expect_equal(collect(reduce_over(x, "mean", c("x", "y"))), 30000)
  expect_equal(collect(reduce_over(x, "sum", c("x", "y"))), 30000 * n)
  y <- lazy_source(.int_square("Int32", 2e7, 100L))
  expect_equal(collect(reduce_over(y, "mean", c("x", "y"))), 2e7)
  expect_equal(collect(reduce_over(y, "sum", c("x", "y"))), 2e11)
})

test_that("a spatial integer sum declares a dtype that holds it", {
  x <- lazy_source(.int_square("Int16", 30000))
  expect_identical(reduce_over(x, "sum", c("x", "y"))@grid@dtype, "i64")
  expect_identical(reduce_over(x, "sum", "x")@grid@dtype, "i64")
  stk <- lazy_stack(list(x, x), along = "t")
  expect_identical(reduce_over(stk, "sum", "t")@grid@dtype, "i32")
  expect_identical(reduce_over(stk, "sum", c("x", "y"))@grid@dtype, "i64")
})

test_that("a 32-bit sum over slices does not wrap", {
  x <- lazy_source(.int_source("Int32", rep(2e9, 600)))
  s <- reduce_over(lazy_stack(rep(list(x), 3)), "sum", "t")
  expect_identical(s@grid@dtype, "i64")
  expect_true(all(collect(s, distributed = FALSE) == 6e9))
})

test_that("64-bit kernel outputs reach R as doubles, across chunks too", {
  x <- lazy_source(.int_source("UInt32", rep(c(5, 4e9), 300)))
  withr::local_options(garry.chunk_target_px = 100)
  got <- collect(x + 1L, distributed = FALSE)
  expect_type(got, "double")
  expect_false(inherits(got, "integer64"))
  expect_equal(range(got), c(6, 4e9 + 1))
})

test_that("a map declares the dtype its kernel returns", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  expect_identical(lazy_map(x, fn = function(v) v / 2)@grid@dtype, "f32")
  expect_identical(lazy_map(x, fn = function(v) v + 1L)@grid@dtype, "i16")
  expect_identical(lazy_map(x, fn = function(v) g_cast(v, "f64"))@grid@dtype, "f64")
  # a carrier is the declared dtype, and a logical stores 0/1 at it
  u <- lazy_source(.int_source("UInt16", rep(3, 600)))
  expect_identical(lazy_map(u, fn = function(v) v + 1L)@grid@dtype, "u16")
  expect_identical(lazy_map(u, fn = function(v) v > 1L)@grid@dtype, "u16")
  # a stack's kernel sees its outer axis
  s <- lazy_stack(rep(list(x), 3), along = "t")
  expect_identical(lazy_map(s, fn = function(v) g_slice_t(v, 1L, 2L) / 2)@grid@dtype, "f32")
})

test_that("a scan and a custom reducer declare the dtype they return", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  s <- lazy_stack(rep(list(x), 3), along = "t")
  body <- function(xs, margin) xs[[1L]] / 2
  expect_identical(scan_over(s, body)@grid@dtype, "f32")
  expect_identical(scan_over(s, function(xs, margin) xs[[1L]])@grid@dtype, "i16")
  expect_identical(reduce_over(s, function(v, dims) g_mean(v, dims), "t")@grid@dtype, "f32")
  expect_identical(reduce_over(s, function(v, dims) g_max(v, dims), "t")@grid@dtype, "i16")
})

test_that("one fn over many same-shaped inputs traces once", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  y <- lazy_source(.int_source("Int16", rep(4, 600)))
  n <- 0L
  real <- garry:::.kernel_out_dtype
  testthat::local_mocked_bindings(
    .kernel_out_dtype = function(...) {
      n <<- n + 1L
      real(...)
    },
    .package = "garry"
  )
  fn <- function(v) v * 2L
  a <- lazy_map(x, fn = fn)
  b <- lazy_map(y, fn = fn)
  expect_identical(n, 1L)
  expect_identical(b@grid@dtype, a@grid@dtype)
  # a reducer differs by the dim it reduces
  s <- lazy_stack(list(x, y), along = "t")
  rd <- function(v, dims) g_mean(v, dims)
  r1 <- reduce_over(s, rd, "t")
  n <- 0L
  r2 <- reduce_over(lazy_stack(list(y, x), along = "t"), rd, "t")
  expect_identical(n, 0L)
  expect_identical(r2@grid@dtype, r1@grid@dtype)
  # another input dtype traces again
  u <- lazy_source(.int_source("UInt16", rep(3, 600)))
  lazy_map(u, fn = fn)
  expect_identical(n, 1L)
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

test_that("an integer buffer refuses a missing value", {
  err <- expect_error(g_upload(matrix(c(1, NaN), 1L), "i16"), class = "garry_nodata_error")
  expect_match(conditionMessage(err), "i16")
  expect_match(conditionMessage(err), "nodata")
  expect_error(g_upload(matrix(c(1L, NA), 1L), "u16"), class = "garry_nodata_error")
  # a float buffer carries it
  expect_true(is.nan(g_download(g_upload(matrix(NaN), "f32"))))
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
  expect_false(anyNA(r))
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

test_that("a wide integer source keeps every value when it reads as float", {
  big <- 16777217 # 2^24 + 1, which f32 rounds
  f <- .int_source("Int32", rep(big, 600))
  x <- lazy_source(f, nodata = -1)
  expect_identical(x@grid@dtype, "f64")
  expect_true(all(collect(x + 0, distributed = FALSE) == big))
  s <- lazy_source(f, scale = 2)
  expect_identical(s@grid@dtype, "f64")
  expect_true(all(collect(s, distributed = FALSE) == 2 * big))
  mean_fn <- function(sh) Reduce(`+`, sh) / length(sh)
  r <- collect(focal_map(lazy_source(f), mean_fn, 1L), distributed = FALSE)
  expect_equal(r[2L, 2L], big)
  # 16-bit sources stay f32
  expect_identical(lazy_source(.int_source("Int16", rep(1, 600)), nodata = -1)@grid@dtype, "f32")
})

test_that("window warps of a wide source keep its values", {
  v <- 1.1 # no f32 holds this
  a <- .int_tile("Float64", v, 0)
  b <- .int_tile("Float64", v, 100)
  g <- grid_spec("EPSG:32632", extent = c(0, 0, 200, 100),
                 dims = c(x = 20L, y = 10L), dtype = "f64")
  x <- lazy_source(c(a, b), grid = g)
  expect_true(all(collect(x, distributed = FALSE) == v))
  expect_true(all(collect(x + 0, distributed = FALSE) == v))
  m <- .int_tile("Float64", v, 0, epsg = "EPSG:32632")
  h <- garry:::gdal_warp_window(m, 1L, g, 0L, 0L, 10L, 10L)
  expect_true(all(h == v))
})

test_that("warp-on-read routes take only what f32 holds", {
  f <- tempfile()
  saveRDS(list(entries = data.frame(slice = "a")), paste0(f, ".meta.rds"))
  node <- function(dtype) {
    SourceNode(
      id = 1L,
      parents = integer(0),
      grid = grid_spec("EPSG:32632", extent = c(0, 0, 10, 10),
                       dims = c(x = 1L, y = 1L), dtype = dtype),
      path = paste0("GTI:", f),
      band = 1L,
      nodata = numeric(0),
      block_dim = integer(0),
      open_options = character(0)
    )
  }
  expect_true(garry:::.gd_source_ok(node("f32")))
  expect_true(garry:::.gd_source_ok(node("u16")))
  expect_false(garry:::.gd_source_ok(node("f64")))
  expect_false(garry:::.gd_source_ok(node("i32")))
})

test_that("every band declares its own dtype", {
  a <- .int_tile("Byte", 7, 0)
  b <- .int_tile("Float32", 1.5, 0)
  vrt <- withr::local_tempfile(fileext = ".vrt")
  band <- function(i, type, f) {
    glue::glue(
      '<VRTRasterBand dataType="{type}" band="{i}"><SimpleSource>',
      '<SourceFilename>{f}</SourceFilename><SourceBand>1</SourceBand>',
      '</SimpleSource></VRTRasterBand>'
    )
  }
  writeLines(c(
    '<VRTDataset rasterXSize="10" rasterYSize="10">',
    glue::glue("<SRS>{gdalraster::srs_to_wkt('EPSG:32632')}</SRS>"),
    "<GeoTransform>0, 10, 0, 100, 0, -10</GeoTransform>",
    band(1L, "Byte", a),
    band(2L, "Float32", b),
    "</VRTDataset>"
  ), vrt)
  ds <- lazy_dataset(vrt)
  expect_identical(ds[[1L]]@grid@dtype, "u8")
  expect_identical(ds[[2L]]@grid@dtype, "f32")
  expect_true(all(collect(ds[[2L]] + 0, distributed = FALSE) == 1.5))
})

test_that("a band type garry has no dtype for is named", {
  f <- .int_tile("CFloat32", 1, 0)
  err <- expect_error(gdal_grid_spec(f), "unsupported GDAL data type")
  expect_match(conditionMessage(err), basename(f), fixed = TRUE)
})

test_that("a raw cube of wide integers keeps its values", {
  big <- 16777217
  f <- .int_tile("Int32", big, 0)
  vrt <- withr::local_tempfile(fileext = ".vrt")
  stage_raw_cube(f, vrt)
  expect_identical(gdal_grid_spec(vrt)$grid@dtype, "f64")
  expect_true(all(collect(lazy_source(vrt), distributed = FALSE) == big))
})

test_that("shrink_footprint keeps its edge over an integer raster", {
  x <- lazy_source(.int_source("Int16", rep(3, 600)))
  m <- collect(shrink_footprint(x, 1L, boundary = "keep"), distributed = FALSE)
  expect_true(all(m == 3))
})

test_that("every route agrees on what a kernel returns", {
  local_pools(2, 1)
  x <- lazy_source(.int_source("Int16", rep(3, 600)))

  # an undeclared float kernel over integers
  z <- lazy_map(x, fn = function(v) v / 2)
  expect_true(all(collect(z, distributed = FALSE) == 1.5))
  expect_true(all(collect(z, distributed = TRUE) == 1.5))
  m <- reduce_over(z, "mean", c("x", "y"))
  expect_equal(collect(m, distributed = FALSE), 1.5)
  expect_equal(collect(m, distributed = TRUE), 1.5)
  for (d in c(FALSE, TRUE)) {
    p <- withr::local_tempfile(fileext = ".tif")
    write_tif(z, p, distributed = d)
    expect_identical(gdal_grid_spec(p)$grid@dtype, "f32")
    expect_true(all(gdal_read_window(p, 1L, 0L, 0L, 30L, 20L) == 1.5))
  }

  # a named dtype is what the kernel hands on
  named <- lazy_map(x, fn = function(v) v / 2, dtype = "i16")
  p <- plan_lazy(list(
    a = reduce_over(named, "mean", c("x", "y")),
    b = reduce_over(named, "max", c("x", "y"))
  ))
  ref <- execute_plan(p)
  got <- execute_plan_mirai(p)
  expect_equal(unname(ref$a), 1)
  expect_equal(unname(got$a), 1)
  expect_equal(unname(got$b), unname(ref$b))

  # a count is the integer it declares
  cnt <- reduce_over(lazy_stack(list(x, x), along = "t"), "count", "t")
  expect_identical(cnt@grid@dtype, "i32")
  y <- lazy_map(cnt, fn = function(v) v + 1L)
  p <- plan_lazy(list(a = y + 1L, b = y + 2L))
  ref <- execute_plan(p)
  got <- execute_plan_mirai(p)
  expect_true(all(ref$a == 4))
  expect_equal(unclass(got$a), unclass(ref$a), ignore_attr = TRUE)
  expect_equal(unclass(got$b), unclass(ref$b), ignore_attr = TRUE)

  # masking gives a band a dtype NaN can live in
  w <- .int_source("Float64", rep(1.1, 600))
  q <- .int_source("Byte", rep(c(0, 1), 300))
  ds <- as_dataset(list(v = x, w = lazy_source(w), q = lazy_source(q)), mask_asset = "q")
  mk <- apply_mask(ds, where = 1, from = "q")
  expect_identical(mk$v@grid@dtype, "f32")
  expect_identical(mk$w@grid@dtype, "f64")
  for (d in c(FALSE, TRUE)) {
    a <- collect(mk$v, distributed = d)
    b <- collect(mk$w, distributed = d)
    expect_identical(sum(is.nan(a)), 300L)
    expect_true(all(a[!is.nan(a)] == 3))
    expect_true(all(b[!is.nan(b)] == 1.1))
  }

  # a predicate dtype runs through a program, and refuses a file
  u <- lazy_source(.int_source("Int16", rep(c(1, 2), 300)))
  pm <- lazy_map(u, fn = function(v) v > 1L, dtype = "pred")
  p <- plan_lazy(list(
    a = lazy_map(pm, fn = function(v) g_ifelse(v, 5, 0)),
    b = lazy_map(pm, fn = function(v) g_ifelse(v, 7, 0))
  ))
  ref <- execute_plan(p)
  got <- execute_plan_mirai(p)
  expect_setequal(as.vector(ref$a), c(0, 5))
  expect_equal(unclass(got$a), unclass(ref$a), ignore_attr = TRUE)
  expect_setequal(as.vector(collect(pm, distributed = FALSE)), c(FALSE, TRUE))
  expect_error(write_tif(pm, tempfile(fileext = ".tif")), "cannot write dtype")
})

test_that("Math on an integer dataset declares f32 per band", {
  x <- lazy_source(.int_source())
  ds <- as_dataset(list(a = x, b = x * 0.5))
  r <- sqrt(ds)
  expect_identical(r$a@grid@dtype, "f32")
  expect_identical(r$b@grid@dtype, "f32")
  expect_equal(collect(r$a), sqrt(collect(x)), tolerance = 1e-6, ignore_attr = TRUE)
})
