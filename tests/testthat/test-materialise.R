# materialise(): execute to local raw cubes, come back lazy. Gates:
# raster and dataset round-trips are value-identical to collecting the
# original; band names / slice dates / mask_asset / ragged bands carry
# through; overwrite guard refuses stale targets; one multi-sink plan.

skip_if_not_installed("anvl")

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
