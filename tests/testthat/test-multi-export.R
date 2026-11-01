# Multi-export collect (design/multi-export-collect.md): a NAMED list of
# LazyRasters plans as ONE graph with one execution and several sinks.
# Gates: multi-export == N single collects (values, layout, gis attr),
# chunk-forced, mixed grids (scan + reduce + stack), file writes, and
# sibling ScanNodes fusing into one compute stage (kalman mean+sd).

test_that("multi-export equals single collects across mixed sinks", {
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
    multi <- .with_chunk_px(px,
      collect(list(cum = sc, mn = red, stack = stk), distributed = FALSE))
    expect_named(multi, c("cum", "mn", "stack"))
    expect_equal(unclass(multi$cum), unclass(s1), tolerance = 1e-6)
    expect_equal(unclass(multi$mn), unclass(s2), tolerance = 1e-6)
    expect_equal(unclass(multi$stack), unclass(s3), tolerance = 1e-6)
    expect_false(is.null(attr(multi$mn, "gis")))
  }
})

test_that("multi-export writes one file per sink from one execution", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f); b <- lazy_source(f)
  stk <- lazy_stack(list(a + 1, b * 2))
  red <- reduce_over(stk, "sum", "t")
  dir <- withr::local_tempdir("me")
  write_tif(list(cum = stk, total = red), dir, distributed = FALSE)
  expect_setequal(list.files(dir), c("cum.tif", "total.tif"))
  ref <- collect(red, distributed = FALSE)
  d <- methods::new(gdalraster::GDALRaster, file.path(dir, "total.tif"))
  on.exit(d$close())
  got <- matrix(d$read(1, 0, 0, 60, 40, 60, 40), 40, 60, byrow = TRUE)
  expect_equal(got, unclass(ref), tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("sibling ScanNodes share one compute stage (kalman mean+sd)", {
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
  expect_error(plan_lazy(list(a + 1)), "names(x)", fixed = TRUE)
  expect_error(plan_lazy(list(x = 1)), "sink 1 must be")
  expect_error(plan_lazy(list(y = a, x = 1)), "sink 2 must be")
})

local({
  local_pools(2, 1, gdal_config = TRUE)
  v <- .fixture_values(60, 40)

  test_that("multi-export runs on daemons as one plan, in memory and streamed", {
    f <- fixture_gradient_f32()
    a <- lazy_source(f); b <- lazy_source(f)
    stk <- lazy_stack(list(a + 1, b * 2))
    sc <- scan_over(stk, function(xs, m)
      g_scan(0, function(c, v) list(carry = c + v, out = c + v),
             xs = xs[[1L]])$out)
    red <- reduce_over(stk, "sum", "t")
    first <- v + 1
    second <- v * 2
    expect_plan(
      list(cum = sc, tot = red),
      list(cum = array(c(first, first + second), c(40L, 60L, 2L)), tot = first + second),
      c(cum = "f32", tot = "f32"),
      legs = list(.leg()),
      px = 400
    )
  })

  # Several groups are one plan and a single group is its own, and neither
  # may decide for itself where it runs: on a pool, collect() would default
  # to it.
  test_that("a grouped collect runs where it is sent", {
    f <- fixture_gradient_f32()
    g <- graph_new()
    s <- function(k) lazy_source(f, graph = g) * k
    ds <- as_dataset(list(B = list(`2024-01-05` = s(1), `2024-01-20` = s(3), `2024-02-03` = s(5))))
    wants <- list(
      month = list(`2024-01` = v * 2, `2024-02` = v * 5),
      year = list(`2024` = v * 3)
    )
    for (period in names(wants)) {
      composites <- reduce_over(group_by_time(ds, period), "median", "t", nan_rm = TRUE)
      for (leg in list(.leg(), .host)) {
        got <- collect(composites, distributed = leg$distributed)
        expect_identical(garry_last_route(), leg$route, info = period)
        expect_named(got, names(wants[[period]]))
        for (nm in names(got)) {
          .expect_cells(unclass(got[[nm]]), wants[[period]][[nm]], info = period)
        }
      }
    }
  })
})
