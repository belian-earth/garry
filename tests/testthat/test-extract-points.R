# extract_points(): gdalraster's point sampler, extended to garry objects.
# Non-garry inputs must behave exactly as gdalraster's own function; garry
# objects read a local source directly, or materialise first.

.pe_src <- function(vals, dir, nb = 1L) {
  f <- file.path(dir, paste0("pe-", substr(rlang::hash(list(vals, nb)), 1L, 8L), ".tif"))
  d <- gdalraster::create("GTiff", f, 60, 40, nb, "Float32", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 400, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  for (b in seq_len(nb)) d$write(b, 0, 0, 60, 40, as.numeric(t(vals * b)))
  d$close()
  f
}

test_that("non-garry inputs delegate to gdalraster unchanged", {
  dir <- withr::local_tempdir()
  vals <- .gg_val(0)
  f <- .pe_src(vals, dir)
  xy <- cbind(c(5, 155, 595), c(395, 285, 5))
  expect_identical(
    extract_points(f, xy),
    gdalraster::pixel_extract(f, xy)
  )
  # a GDALRaster object passes through too
  ds <- methods::new(gdalraster::GDALRaster, f)
  on.exit(ds$close())
  expect_identical(extract_points(ds, xy), gdalraster::pixel_extract(ds, xy))
  # and the extra gdalraster arguments still reach it
  expect_identical(
    extract_points(f, xy, interp = "bilinear"),
    gdalraster::pixel_extract(f, xy, interp = "bilinear")
  )
})

test_that("a bare local source is read directly, matching gdalraster", {
  dir <- withr::local_tempdir()
  vals <- .gg_val(0)
  f <- .pe_src(vals, dir, nb = 3L)
  xy <- cbind(c(5, 155, 595), c(395, 285, 5))
  x <- lazy_source(f, band = 1L)
  expect_identical(
    unname(as.matrix(extract_points(x, xy, bands = 1L))),
    unname(as.matrix(gdalraster::pixel_extract(f, xy, bands = 1L)))
  )
  # the expected values, closed-form on the .gg_grid geometry
  expect_equal(
    as.numeric(extract_points(x, xy, bands = 1L)),
    c(vals[1, 1], vals[12, 16], vals[40, 60])
  )
})

test_that("wk_xy points supply their own CRS", {
  dir <- withr::local_tempdir()
  vals <- .gg_val(0)
  f <- .pe_src(vals, dir)
  native <- wk::xy(c(5, 155), c(395, 285), crs = "EPSG:3857")
  ll <- gdalraster::transform_xy(
    cbind(c(5, 155), c(395, 285)),
    gdalraster::srs_to_wkt("EPSG:3857"), gdalraster::srs_to_wkt("EPSG:4326")
  )
  p4326 <- wk::xy(ll[, 1L], ll[, 2L], crs = "EPSG:4326")
  expect_equal(
    as.numeric(extract_points(f, p4326)),
    as.numeric(extract_points(f, native))
  )
  expect_error(extract_points(f, wk::xy(5, 395)), "no CRS")
  # a plain matrix keeps gdalraster's own semantics
  expect_identical(
    extract_points(f, cbind(5, 395)),
    gdalraster::pixel_extract(f, cbind(5, 395))
  )
})

test_that("an unmaterialised pipeline is refused, not silently written", {
  dir <- withr::local_tempdir()
  vals <- .gg_val(0)
  f <- .pe_src(vals, dir)
  x <- lazy_map(lazy_source(f), fn = function(v) v * 2 + 1, dtype = "f32")
  pts <- wk::xy(c(5, 155), c(395, 285), crs = "EPSG:3857")
  expect_error(extract_points(x, pts), "materialise")
  # materialise first and it works, on the values the pipeline computes
  cube <- materialise(
    as_dataset(list(v = stats::setNames(list(x), "2023-01-01"))),
    dir = dir, name = "cube", overwrite = TRUE
  )
  expect_equal(
    as.numeric(extract_points(cube, pts)),
    c(vals[1, 1], vals[12, 16]) * 2 + 1
  )
})

test_that("a dataset extracts one column per band, in band order", {
  dir <- withr::local_tempdir()
  vals <- .gg_val(0)
  fa <- .pe_src(vals, dir)
  fb <- .pe_src(vals * 3, dir)
  ds <- as_dataset(list(A = lazy_source(fa), B = lazy_source(fb)))
  pts <- wk::xy(c(5, 155), c(395, 285), crs = "EPSG:3857")
  got <- extract_points(ds, pts)
  expect_equal(dim(got), c(2L, 2L))
  expect_equal(as.numeric(got[, 1L]), c(vals[1, 1], vals[12, 16]))
  expect_equal(as.numeric(got[, 2L]), as.numeric(got[, 1L]) * 3)
  expect_equal(colnames(got), c("A", "B"))
})
