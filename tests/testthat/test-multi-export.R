# Multi-export collect (design/multi-export-collect.md): a NAMED list of
# LazyRasters plans as ONE graph with one execution and several sinks.
# Gates: multi-export == N single collects (values, layout, gis attr),
# chunk-forced, mixed grids (scan + reduce + stack), file writes, and
# sibling ScanNodes fusing into one compute stage (kalman mean+sd).

.with_px <- function(px, code) {
  old <- options(garry.chunk_target_px = px)
  on.exit(options(old))
  force(code)
}

test_that("multi-export equals single collects across mixed sinks", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  a <- lazy_source(f); b <- lazy_source(f)
  stk <- lazy_stack(list(a + 1, b * 2, a - b))
  sc <- scan_over(stk, function(xs, m)
    g_scan(0, function(c, v) list(carry = c + v, out = c + v),
           xs = xs[[1L]])$out)
  red <- reduce_over(stk, "mean", "t")

  s1 <- collect(sc, distributed = FALSE)
  s2 <- collect(red, distributed = FALSE)
  s3 <- collect(stk, distributed = FALSE)
  for (px in c(400, 1e6)) {
    multi <- .with_px(px,
      collect(list(cum = sc, mn = red, stack = stk), distributed = FALSE))
    expect_named(multi, c("cum", "mn", "stack"))
    expect_equal(unclass(multi$cum), unclass(s1), tolerance = 1e-6)
    expect_equal(unclass(multi$mn), unclass(s2), tolerance = 1e-6)
    expect_equal(unclass(multi$stack), unclass(s3), tolerance = 1e-6)
    expect_false(is.null(attr(multi$mn, "gis")))
  }
})

test_that("multi-export writes one file per sink from one execution", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  a <- lazy_source(f); b <- lazy_source(f)
  stk <- lazy_stack(list(a + 1, b * 2))
  red <- reduce_over(stk, "sum", "t")
  dir <- withr::local_tempdir("me")
  collect(list(cum = stk, total = red), path = dir, distributed = FALSE)
  expect_setequal(list.files(dir), c("cum.tif", "total.tif"))
  ref <- collect(red, distributed = FALSE)
  d <- methods::new(gdalraster::GDALRaster, file.path(dir, "total.tif"))
  on.exit(d$close())
  got <- matrix(d$read(1, 0, 0, 60, 40, 60, 40), 40, 60, byrow = TRUE)
  expect_equal(got, unclass(ref), tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("sibling ScanNodes share one compute stage (kalman mean+sd)", {
  skip_if_not_installed("anvl")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")
  f <- fixture_gradient_f32()
  g <- graph_new()
  stk <- lazy_stack(lapply(1:4, function(i)
    lazy_source(f, graph = g) * i), along = "t")
  sm <- kalman_smooth(stk, 1, 0.1, 2)
  p <- collect(list(mean = sm$mean, sd = sm$sd), plan_only = TRUE)
  expect_identical(sum(vapply(p@stages, function(s)
    s@kind == "compute", logical(1))), 1L)     # both scans, one stage
  multi <- collect(list(mean = sm$mean, sd = sm$sd), distributed = FALSE)
  m1 <- collect(sm$mean, distributed = FALSE)
  m2 <- collect(sm$sd, distributed = FALSE)
  expect_equal(unclass(multi$mean), unclass(m1), tolerance = 1e-6)
  expect_equal(unclass(multi$sd), unclass(m2), tolerance = 1e-6)
})

test_that("multi-export validates its input", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  expect_error(plan_lazy(list(a + 1)))                   # unnamed
  expect_error(plan_lazy(list(x = 1)))                   # not a LazyRaster
})

test_that("multi-export: distributed == single-process", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  f <- fixture_gradient_f32()
  a <- lazy_source(f); b <- lazy_source(f)
  stk <- lazy_stack(list(a + 1, b * 2, a - b))
  sc <- scan_over(stk, function(xs, m)
    g_scan(0, function(c, v) list(carry = c + v, out = c + v),
           xs = xs[[1L]])$out)
  red <- reduce_over(stk, "mean", "t")
  md <- .with_px(400, collect(list(cum = sc, mn = red), distributed = TRUE))
  ms <- .with_px(400, collect(list(cum = sc, mn = red), distributed = FALSE))
  for (nm in names(ms))
    expect_equal(unclass(md[[nm]]), unclass(ms[[nm]]), tolerance = 1e-6,
                 label = nm)
})

test_that("multi-export: distributed streamed writes match memory results", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  f <- fixture_gradient_f32()
  a <- lazy_source(f); b <- lazy_source(f)
  stk <- lazy_stack(list(a + 1, b * 2))
  sc <- scan_over(stk, function(xs, m)
    g_scan(0, function(c, v) list(carry = c + v, out = c + v),
           xs = xs[[1L]])$out)
  red <- reduce_over(stk, "sum", "t")
  dir <- withr::local_tempdir("mstream")
  .with_px(400, collect(list(cum = sc, tot = red), path = dir,
                        distributed = TRUE))
  ms <- .with_px(400, collect(list(cum = sc, tot = red),
                              distributed = FALSE))
  rd <- function(fp, b) {
    d <- methods::new(gdalraster::GDALRaster, fp)
    on.exit(d$close())
    matrix(d$read(b, 0, 0, 60, 40, 60, 40), 40, 60, byrow = TRUE)
  }
  expect_equal(rd(file.path(dir, "cum.tif"), 2), unclass(ms$cum)[, , 2],
               tolerance = 1e-6, ignore_attr = TRUE)   # memory layout is (y,x,t)
  expect_equal(rd(file.path(dir, "tot.tif"), 1), unclass(ms$tot),
               tolerance = 1e-6, ignore_attr = TRUE)
})
