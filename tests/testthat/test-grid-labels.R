# GridSpec labels: optional per-axis labels for the non-spatial dims
# (slice dates on t, band names on band). Labels are metadata — no
# planner pass reads them, grid_equal ignores them — carried by
# lazy_stack (layer names), dropped by reduce, and unlocking labelled
# output, label selection (time_sel/band_sel), group_by_time on bare
# cubes, and dt-aware scan bodies.

.gl_base <- function() {
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400), dims = c(60L, 40L))
  list(crs = g@crs, transform = g@transform, extent = g@extent)
}

test_that("labels validate against dims and grid_equal ignores them", {
  b <- .gl_base()
  g3 <- GridSpec(crs = b$crs, transform = b$transform, extent = b$extent,
                 dims = c(x = 60L, y = 40L, t = 2L), dtype = "f32",
                 labels = list(t = c("2023-01-01", "2023-01-02")))
  expect_identical(g3@labels$t, c("2023-01-01", "2023-01-02"))
  expect_error(GridSpec(crs = b$crs, transform = b$transform,
                        extent = b$extent, dims = c(x = 60L, y = 40L, t = 2L),
                        dtype = "f32", labels = list(t = "one")),
               "length")
  expect_error(GridSpec(crs = b$crs, transform = b$transform,
                        extent = b$extent, dims = c(x = 60L, y = 40L, t = 2L),
                        dtype = "f32", labels = list(x = c("a", "b"))),
               "non-spatial")
  bare <- GridSpec(crs = b$crs, transform = b$transform, extent = b$extent,
                   dims = c(x = 60L, y = 40L, t = 2L), dtype = "f32")
  expect_true(grid_equal(g3, bare))          # labels are planning-neutral
})

test_that("lazy_stack layer names become labels; reduce drops them; scan keeps them", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  s <- lazy_stack(list("2023-01-01" = a + 0, "2023-01-02" = a * 2),
                  along = "t")
  expect_identical(s@grid@labels$t, c("2023-01-01", "2023-01-02"))
  r <- reduce_over(s, "median", "t")
  expect_null(r@grid@labels$t)
  sc <- scan_over(s, function(xs, margin) xs[[1L]], over = "t")
  expect_identical(sc@grid@labels$t, s@grid@labels$t)
  # unnamed layers stay unlabelled, as before
  s2 <- lazy_stack(list(a + 0, a * 2), along = "t")
  expect_length(s2@grid@labels, 0L)
})

test_that("time_sel selects by exact label, prefix, and position", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  s <- lazy_stack(list("2023-01-05" = a + 1, "2023-06-10" = a + 2,
                       "2023-06-20" = a + 3), along = "t")
  june <- time_sel(s, "2023-06")             # prefix: both June slices
  expect_identical(june@grid@labels$t, c("2023-06-10", "2023-06-20"))
  expect_identical(unname(june@grid@dims[["t"]]), 2L)
  one <- time_sel(s, "2023-01-05")           # single match -> bare layer
  expect_identical(unname(one@grid@dims), c(60L, 40L))
  pos <- time_sel(s, c(1L, 3L))
  expect_identical(pos@grid@labels$t, c("2023-01-05", "2023-06-20"))
  expect_error(time_sel(s, "2024"), "match")
  expect_error(time_sel(a + 1, "2023"), "labels")
})

test_that("stack_bands carries band labels; band_sel selects", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(
    V1 = list(s1 = src() * 1, s2 = src() * 2),
    V2 = list(s1 = src() * 3, s2 = src() * 4)
  ))
  x <- stack_bands(reduce_over(ds, "mean", "t"))
  expect_identical(x@grid@labels$band, c("V1", "V2"))
  v2 <- band_sel(x, "V2")
  expect_identical(unname(v2@grid@dims), c(60L, 40L))
})

test_that("group_by_time works on a bare labelled cube", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  s <- lazy_stack(list("2023-01-05" = a + 1, "2023-02-10" = a + 2,
                       "2023-02-20" = a + 3), along = "t")
  gr <- group_by_time(s, "month")
  expect_identical(names(gr@groups), c("2023-01", "2023-02"))
  out <- collect(reduce_over(gr, "mean", "t"))
  expect_identical(names(out), c("2023-01", "2023-02"))
  base <- collect(a + 1)
  expect_equal(out[["2023-01"]], base, tolerance = 1e-6,
               ignore_attr = "gis")
  expect_equal(out[["2023-02"]], base + 1.5, tolerance = 1e-6,
               ignore_attr = "gis")
  expect_error(group_by_time(a + 1, "month"), "labelled")
})

test_that("collect writes t labels as band descriptions on unreduced stacks", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  s <- lazy_stack(list("2023-01-01" = a + 0, "2023-01-02" = a * 2),
                  along = "t")
  path <- withr::local_tempfile(fileext = ".tif")
  collect(s, path = path)
  r <- new(gdalraster::GDALRaster, path)
  on.exit(r$close())
  expect_equal(vapply(1:2, function(b) r$getDescription(b), character(1)),
               c("2023-01-01", "2023-01-02"))
})

test_that("a 3-formal scan body receives the axis labels", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  s <- lazy_stack(list(d1 = a + 0, d2 = a * 2), along = "t")
  body <- function(xs, margin, labels) {
    if (identical(labels, c("d1", "d2"))) xs[[1L]] + 100 else xs[[1L]]
  }
  got <- collect(scan_over(s, body, over = "t"))
  want <- collect(s) + 100
  expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("mask join='inner' pairs shared slices; 'exact' aborts prescriptively", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(
    V = list(s1 = src() * 1, s2 = src() * 2, s3 = src() * 3),
    Q = list(s1 = src(), s2 = src() + 1)
  ), mask_asset = "Q")
  expect_error(mask(ds, where = c(2)), "do not align")
  masked <- suppressMessages(mask(ds, where = c(2), join = "inner"))
  expect_identical(names(masked@bands$V), c("s1", "s2"))
})
