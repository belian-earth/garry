# API ergonomics from the datamodel review: comparison / ^ / %% Ops and
# the Math group on LazyRaster+LazyDataset, grid_diff() embedded in
# alignment aborts, as_terra() from the gis attribute, and fill_gaps()
# (ffill / bfill / linear) as scan_over bodies.
#
# The gradient fixture runs from 101 to 4060, so a cut at 2000 splits it.


test_that("comparisons produce f32 0/1 masks that compose", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- .fixture_values(60, 40)
  expect_equal(collect(a > 2000), (m > 2000) * 1, tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(collect(2000 < a), (m > 2000) * 1, tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(collect(a <= 2000), (m <= 2000) * 1, tolerance = 1e-6,
               ignore_attr = TRUE)
  g <- graph_new()
  b <- lazy_source(f, graph = g)
  expect_equal(collect((b * 2) == (b + b)), matrix(1, 40, 60),
               tolerance = 0, ignore_attr = TRUE)
  expect_equal(collect(b != b), matrix(0, 40, 60), tolerance = 0,
               ignore_attr = TRUE)
  # composes as map algebra: (x > 2000) * x
  expect_equal(collect((a > 2000) * a), (m > 2000) * m, tolerance = 1e-5,
               ignore_attr = TRUE)
  expect_identical((a > 2000)@grid@dtype, "f32")
})

test_that("^ and %% work on rasters and datasets", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- .fixture_values(60, 40)
  expect_equal(collect(a^2), m^2, tolerance = 1e-5, ignore_attr = TRUE)
  expect_equal(collect(a %% 7), m %% 7, tolerance = 1e-5,
               ignore_attr = TRUE)
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(V = list(s1 = src())))
  out <- collect(reduce_over(ds^2, "mean", "t"))
  expect_equal(out, m^2, tolerance = 1e-5, ignore_attr = TRUE)
})

test_that("^ on integers is R's double, so it neither wraps nor truncates", {
  pow <- function(p, want) {
    expect_identical(p@grid@dtype, "f32")
    expect_equal(collect(p), want, tolerance = 1e-6, ignore_attr = TRUE)
  }
  vals <- c(-300, -1, 7, 300)
  x <- lazy_source(fixture_tile(vals, "Int16", nx = 2L, ny = 2L))
  m <- matrix(vals, 2L, 2L, byrow = TRUE)
  pow(x^2L, m^2) # 90000 is no i16
  pow(x^3L, m^3) # an odd power keeps the sign
  pow(x^-1L, m^-1) # a negative one is a fraction
  # a Byte runs on an i16 carrier, which holds no 62500 either
  pow(lazy_source(fixture_tile(250, "Byte", nx = 2L, ny = 2L))^2L, matrix(62500, 2L, 2L))
  vals <- c(1, 2, 15, 20)
  e <- lazy_source(fixture_tile(vals, "Int16", nx = 2L, ny = 2L))
  m <- matrix(vals, 2L, 2L, byrow = TRUE)
  pow(2L^e, 2^m)
  pow(e^e, m^m)
})

test_that("Math group generics map elementwise on raster and dataset", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- .fixture_values(60, 40)
  expect_equal(collect(sqrt(a)), sqrt(m), tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(collect(log(a)), log(m), tolerance = 1e-5,
               ignore_attr = TRUE)
  expect_equal(collect(abs(a - 2000)), abs(m - 2000), tolerance = 1e-5,
               ignore_attr = TRUE)
  expect_equal(collect(round(a / 7)), round(m / 7), tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_error(cumsum(a), "scan_over")
  expect_error(signif(a), "round")
  g <- graph_new()
  ds <- as_dataset(list(V = list(s1 = lazy_source(f, graph = g))))
  out <- collect(reduce_over(sqrt(ds), "mean", "t"))
  expect_equal(out, sqrt(m), tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("Math on integers keeps the dtype and R's values at its ends", {
  # -32768 is left out: its absolute value is no i16
  rows <- list(
    i16 = list(type = "Int16", vals = c(-32767, -1, 0, 32767)),
    u16 = list(type = "UInt16", vals = c(0, 1, 40000, 65535))
  )
  for (dt in names(rows)) {
    x <- lazy_source(fixture_tile(rows[[dt]]$vals, rows[[dt]]$type, nx = 2L, ny = 2L))
    m <- matrix(rows[[dt]]$vals, 2L, 2L, byrow = TRUE)
    for (verb in c("abs", "sign", "floor", "ceiling", "trunc", "round")) {
      fn <- get(verb, envir = baseenv())
      expect_plan(fn(x), fn(m), dt, file = FALSE, info = paste(dt, verb))
    }
  }
})

test_that("Ops on integers follow R below zero", {
  vals <- c(-300, -1, 7, 300)
  x <- lazy_source(fixture_tile(vals, "Int16", nx = 2L, ny = 2L))
  m <- matrix(vals, 2L, 2L, byrow = TRUE)
  expect_plan(x + 1L, m + 1, "i16", file = FALSE)
  expect_plan(2L - x, 2 - m, "i16", file = FALSE)
  expect_plan(-x, -m, "i16", file = FALSE)
  expect_plan(x %% 7L, m %% 7, "i16", file = FALSE)
  expect_plan(x %% -7L, m %% -7, "i16", file = FALSE)
  expect_plan(x > -1L, (m > -1) * 1, "f32", file = FALSE)
  expect_plan(x == 7L, (m == 7) * 1, "f32", file = FALSE)
})

# Each way an operator takes an operand, as a named list of verbs.
.sugar_forms <- function(op) {
  f <- get(op, envir = baseenv())
  forms <- list(
    "x, 2L" = function(x) f(x, 2L),
    "2L, x" = function(x) f(2L, x),
    "x, 2.5" = function(x) f(x, 2.5),
    "2.5, x" = function(x) f(2.5, x),
    "x, x" = function(x) f(x, x)
  )
  stats::setNames(forms, paste(op, names(forms)))
}

test_that("every Ops and Math verb declares the dtype its kernel returns", {
  # Ops and Math write their dtype by hand and skip the trace a map takes, so
  # the two can drift. This traces each one abstractly: it compiles nothing.
  # Comparisons all cast to f32, so one stands for the six. u8 and i32 reach a
  # kernel on the two integer carriers i16 and u16 share.
  math <- c("round", grep("^cum", methods::getGroupMembers("Math"), value = TRUE, invert = TRUE))
  verbs <- c(
    lapply(stats::setNames(math, math), get, envir = baseenv()),
    unlist(lapply(c("+", "-", "*", "/", "^", "%%", ">"), .sugar_forms), recursive = FALSE),
    list("unary -" = function(x) -x, "!" = function(x) !x,
         "&" = function(x) x & x, "|" = function(x) x | x)
  )
  for (dt in c("u8", "i32", "f32", "f64")) {
    x <- lazy_source_stub("x.tif", dtype = dt)
    rows <- vapply(verbs, function(verb) {
      r <- verb(x)
      n <- graph_get(r@graph, r@node_id)
      k <- length(n@parents)
      c(
        kernel = garry:::.kernel_out_dtype(
          function(inputs) do.call(n@fn, inputs),
          rep(dt, k),
          rep(list(c(2L, 2L)), k)
        ),
        declared = garry:::.input_dtype(r@grid@dtype)
      )
    }, character(2))
    expect_identical(rows["kernel", ], rows["declared", ], info = dt)
  }
})

test_that("grid_diff names the first differing component, aborts embed it", {
  g1 <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400), dims = c(60L, 40L))
  g2 <- grid_spec("EPSG:32632", extent = c(0, 0, 600, 400), dims = c(60L, 40L))
  expect_match(grid_diff(g1, g2), "CRS differs")
  g3 <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400), dims = c(30L, 20L))
  expect_match(grid_diff(g1, g3), "resolution differs")
  g4 <- grid_spec("EPSG:3857", extent = c(3, 0, 603, 400), dims = c(60L, 40L))
  expect_match(grid_diff(g1, g4), "extents differ by 0.3 px in x")
  expect_match(grid_diff(g1, g1), "grids are equal")

  f <- fixture_gradient_f32()
  meta <- gdal_grid_spec(f)
  a <- lazy_source(f)
  shifted <- GridSpec(crs = meta$grid@crs,
                      transform = meta$grid@transform + c(3, 0, 0, 0, 0, 0),
                      extent = meta$grid@extent + c(3, 0, 3, 0),
                      dims = meta$grid@dims, dtype = meta$grid@dtype)
  b <- lazy_source(f, grid = shifted, block_dim = meta$block_dim)
  expect_error(a + b, "extents differ")
})

test_that("as_terra round-trips geometry, values and band names", {
  f <- fixture_gradient_f32()
  out <- collect(lazy_source(f) + 0)
  bands <- collect(as_dataset(list(a = lazy_source(f), b = lazy_source(f) * 2)))
  got <- .with_terra(function(x) {
    r <- garry::as_terra(x$out)
    list(
      dim = dim(r),
      ext = as.vector(terra::ext(r)),
      values = terra::as.matrix(r, wide = TRUE),
      names = names(garry::as_terra(x$bands)),
      no_gis = tryCatch(garry::as_terra(matrix(1, 2, 2)), error = conditionMessage)
    )
  }, list(out = out, bands = bands))
  gis <- attr(out, "gis")
  expect_equal(unname(got$dim[1:2]), c(nrow(out), ncol(out)))
  expect_equal(got$ext, gis$bbox[c(1L, 3L, 2L, 4L)], ignore_attr = TRUE)
  expect_equal(got$values, out, tolerance = 1e-6, ignore_attr = TRUE)
  expect_identical(got$names, c("a", "b"))
  expect_match(got$no_gis, "gis")
})

# A layer with a hole wherever the gradient passes 2000, and that hole.
.sugar_hole <- function(x) {
  lazy_map(x, fn = function(v) g_ifelse(v > 2000, NaN, v), dtype = "f32")
}
.sugar_gap <- function() .fixture_values(60, 40) > 2000

test_that("fill_gaps ffill/bfill/linear match the plain-R oracle", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  s <- lazy_stack(list(s1 = a + 0, s2 = .sugar_hole(a), s3 = a * 2), along = "t")
  gap <- .sugar_gap()
  m1 <- .fixture_values(60, 40)
  m2 <- m1
  m2[gap] <- NaN
  m3 <- m1 * 2

  ff <- collect(fill_gaps(s, "ffill"))
  expect_equal(ff[, , 2][gap], m1[gap], tolerance = 1e-6)
  expect_equal(ff[, , 2][!gap], m2[!gap], tolerance = 1e-6)
  expect_equal(ff[, , 1], m1, tolerance = 1e-6)

  bf <- collect(fill_gaps(s, "bfill"))
  expect_equal(bf[, , 2][gap], m3[gap], tolerance = 1e-6)
  expect_equal(bf[, , 2][!gap], m2[!gap], tolerance = 1e-6)

  li <- collect(fill_gaps(s, "linear"))
  expect_equal(li[, , 2][gap], ((m1 + m3) / 2)[gap], tolerance = 1e-5)
  expect_equal(li[, , 2][!gap], m2[!gap], tolerance = 1e-6)
  # a leading gap falls back to bfill
  s2 <- lazy_stack(list(s1 = .sugar_hole(a), s2 = a * 2), along = "t")
  li2 <- collect(fill_gaps(s2, "linear"))
  expect_equal(li2[, , 1][gap], m3[gap], tolerance = 1e-6)
  expect_equal(li2[, , 1][!gap], m1[!gap], tolerance = 1e-6)
})

test_that("fill_gaps on a dataset fills each value band", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  ds <- as_dataset(list(V = list(s1 = a + 0, s2 = .sugar_hole(a))))
  filled <- fill_gaps(ds, "ffill")
  out <- collect(filled[["V"]])
  # the hole takes the layer before it, which is the same gradient
  expect_equal(out[, , 2], .fixture_values(60, 40), tolerance = 1e-6, ignore_attr = TRUE)
})
