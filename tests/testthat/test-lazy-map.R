# lazy_map: the user-facing elementwise map (no IR types in sight).

skip_if_not_installed("anvl")

test_that("single-input map with g_* vocabulary matches the reference", {
  f <- fixture_gradient_f32()
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  a <- lazy_source(f)

  out <- lazy_map(a, fn = function(x) {
    g_ifelse(x > 2000, NaN, x / 100)
  })
  expect_identical(out@grid@dtype, "f32")
  got <- collect(out)

  want <- ifelse(m > 2000, NaN, m / 100)
  expect_identical(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("multi-input map: QA masking with dtype override", {
  paths <- vapply(1:2, function(i) {
    fp <- file.path(tempdir(), sprintf("garry-lm-%d.tif", i))
    ds <- gdalraster::create("GTiff", fp, 20, 15, 1,
                             if (i == 1) "Int16" else "Byte",
                             return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 150, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    vals <- if (i == 1) seq_len(300) else rep(c(0L, 2L, 0L), length.out = 300)
    ds$write(1, 0, 0, 20, 15, as.numeric(vals))
    ds$close()
    fp
  }, character(1))

  band <- lazy_source(paths[[1]])   # i16
  qa <- lazy_source(paths[[2]])     # u8

  masked <- lazy_map(band, qa, dtype = "f32", fn = function(x, q) {
    bad <- g_bitand(g_cast(q, "i32"), 2L) > 0
    g_ifelse(bad, NaN, g_cast(x, "f32"))
  })
  expect_identical(masked@grid@dtype, "f32")

  got <- collect(masked)
  b <- gdal_read_window(paths[[1]], 1L, 0L, 0L, 20L, 15L)
  q <- gdal_read_window(paths[[2]], 1L, 0L, 0L, 20L, 15L)
  want <- ifelse(bitwAnd(as.integer(q), 2L) > 0, NaN, b)
  dim(want) <- dim(b)
  expect_identical(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("dtype promotion and cross-graph merge behave like operators", {
  g <- graph_new()
  f <- fixture_gradient_f32()
  a <- lazy_source(f, graph = g)
  b <- lazy_source(fixture_i16_nodata())      # separate graph, f32 (nodata)
  expect_error(lazy_map(a, b, fn = `+`), "same grid")

  a2 <- lazy_source(f)
  s <- lazy_map(a, a2, fn = function(x, y) x + y)   # cross-graph, same file
  sources <- Filter(function(i)
    S7::S7_inherits(graph_get(s@graph, i), SourceNode),
    graph_ids(s@graph))
  expect_length(sources, 1L)                        # dedup (D6)
  got <- collect(s)
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  expect_equal(got, 2 * m, tolerance = 1e-5, ignore_attr = "gis")
})
