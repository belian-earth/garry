# materialise(): execute to local raw cubes, come back lazy. Gates:
# raster and dataset round-trips are value-identical to collecting the
# original; band names / slice dates / mask_asset / ragged bands carry
# through; overwrite guard refuses stale targets; one multi-sink plan.


.mat_fixture <- function(ragged = FALSE) {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function(k) lazy_source(f, graph = g) * k
  b04 <- stats::setNames(list(s(1), s(2), s(3)),
                         c("2024-01-05", "2024-01-20", "2024-02-03"))
  qa <- stats::setNames(list(s(10), s(20), s(30)), names(b04))
  b08 <- stats::setNames(list(s(5), s(6), s(7)), names(b04))
  if (ragged) b08 <- b08[-2L]
  as_dataset(list(B04 = b04, B08 = b08, QA = qa), mask_asset = "QA")
}

test_that("a materialised raster reopens with identical values", {
  f <- fixture_gradient_f32()
  lr <- lazy_source(f) * 3 + 1
  d <- withr::local_tempdir()
  m <- materialise(lr, d, name = "r", distributed = FALSE)
  expect_s7_class(m, garry::LazyRaster)
  expect_equal(collect(m, distributed = FALSE),
               collect(lr, distributed = FALSE),
               tolerance = 1e-6, ignore_attr = TRUE)
  # the checkpoint unlocks align() on what was a computed raster
  coarse <- grid_spec(crs = m@grid@crs,
                      extent = c(xmin(m), ymin(m), xmax(m), ymax(m)),
                      res = 3 * res(m)[[1L]])
  expect_s7_class(align(m, coarse, resampling = "average"),
                  garry::LazyRaster)
})

test_that("a materialised dataset round-trips structure and values", {
  ds <- .mat_fixture()
  d <- withr::local_tempdir()
  m <- materialise(ds, d, name = "z", distributed = FALSE)
  expect_s7_class(m, garry::LazyDataset)
  expect_identical(names(m@bands), names(ds@bands))
  expect_identical(m@mask_asset, "QA")
  expect_identical(names(m@bands$B04), names(ds@bands$B04))
  for (b in names(ds@bands))
    expect_equal(collect(m[[b]], distributed = FALSE),
                 collect(ds[[b]], distributed = FALSE),
                 tolerance = 1e-6, ignore_attr = TRUE)
  # three slice cubes on disk, three bands each
  fs <- sort(list.files(d, pattern = "\\.vrt$", full.names = TRUE))
  expect_length(fs, 3L)
  r <- new(gdalraster::GDALRaster, fs[[1L]])
  expect_identical(r$getRasterCount(), 3L)
  expect_identical(vapply(1:3, function(k) r$getDescription(k), ""),
                   c("B04", "B08", "QA"))
  r$close()
})

test_that("ragged bands shrink their dates' cubes and rebuild", {
  ds <- .mat_fixture(ragged = TRUE)
  d <- withr::local_tempdir()
  m <- materialise(ds, d, name = "z", distributed = FALSE)
  expect_identical(names(m@bands$B08),
                   c("2024-01-05", "2024-02-03"))
  jan20 <- new(gdalraster::GDALRaster,
               file.path(d, "z-2024-01-20.vrt"))
  expect_identical(jan20$getRasterCount(), 2L)   # B04 + QA only
  expect_identical(vapply(1:2, function(k) jan20$getDescription(k), ""),
                   c("B04", "QA"))
  jan20$close()
  expect_equal(collect(m[["B08"]], distributed = FALSE),
               collect(ds[["B08"]], distributed = FALSE),
               tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("existing targets are refused without overwrite", {
  ds <- .mat_fixture()
  d <- withr::local_tempdir()
  materialise(ds, d, name = "z", distributed = FALSE)
  expect_error(materialise(ds, d, name = "z", distributed = FALSE),
               "already exists")
  m <- materialise(ds, d, name = "z", overwrite = TRUE,
                   distributed = FALSE)
  expect_s7_class(m, garry::LazyDataset)
})

test_that("masking works unchanged on the rebuilt dataset", {
  ds <- .mat_fixture()
  d <- withr::local_tempdir()
  m <- materialise(ds, d, name = "z", distributed = FALSE)
  masked <- mask(m, where = function(f) g_cast(f > 15, "f32"))
  out <- collect(masked[["B04"]], distributed = FALSE)
  ref <- collect(mask(ds, where = function(f) g_cast(f > 15, "f32"))[["B04"]],
                 distributed = FALSE)
  expect_equal(out, ref, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("dir defaults to a unique announced temp directory", {
  f <- fixture_gradient_f32()
  lr <- lazy_source(f) * 2
  expect_message(m1 <- materialise(lr, distributed = FALSE),
                 "session-temporary")
  suppressMessages(m2 <- materialise(lr, distributed = FALSE))
  n1 <- graph_get(m1@graph, m1@node_id)
  n2 <- graph_get(m2@graph, m2@node_id)
  expect_false(identical(n1@path, n2@path))   # unique per call
  expect_true(startsWith(n1@path, tempdir()))
  expect_equal(collect(m1, distributed = FALSE),
               collect(m2, distributed = FALSE), tolerance = 1e-6,
               ignore_attr = TRUE)
})

test_that("a single-slice dataset materialises to one cube", {
  # A composite (reduce_over drops the time axis) and the file form of
  # lazy_dataset() both leave one unnamed layer per band. There are no
  # dates to key cubes by and none are needed: one cube, a band per band.
  dir <- withr::local_tempdir()
  f <- file.path(dir, "src.tif")
  d <- gdalraster::create("GTiff", f, 40, 30, 3, "Float32", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 300, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  for (b in 1:3) {
    d$setDescription(b, paste0("A0", b))
    d$write(b, 0, 0, 40, 30, rep(b * 1.5, 40 * 30))
  }
  d$close()

  x <- lazy_dataset(f) |> lazy_map(fn = function(v) v * 2, dtype = "f32")
  m <- materialise(x, dir = file.path(dir, "cube"))
  expect_named(m@bands, c("A01", "A02", "A03"))
  expect_equal(unname(collect(m[["A02"]])[1, 1]), 6)
  # and it is a plain local cube, so extraction reads it directly
  pts <- wk::xy(c(15, 205), c(295, 105), crs = "EPSG:3857")
  v <- extract_points(m, pts)
  expect_equal(dim(v), c(2L, 3L))
  expect_equal(as.numeric(v[1L, ]), c(3, 6, 9))
})

test_that("a named list of lazy rasters materialises in one execution, one cube each", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  x <- list(twice = a * 2, plus = a + 1)
  d <- withr::local_tempdir()
  m <- materialise(x, dir = d, name = "pred", distributed = FALSE)
  expect_named(m, c("twice", "plus"))
  expect_true(all(file.exists(file.path(d, c("pred-twice.vrt", "pred-plus.vrt")))))
  ref <- execute_plan(plan_lazy(a))
  expect_equal(execute_plan(plan_lazy(m$twice)), ref * 2, tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(execute_plan(plan_lazy(m$plus)), ref + 1, tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_error(materialise(list(a * 2, a + 1), dir = d), "names")
  expect_error(materialise(x, dir = d, name = "pred"), "exist|overwrite")
})
