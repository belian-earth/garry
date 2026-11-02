# A local file written out whole, cells and type as they are, goes straight
# through GDAL. Anything else moves its values through the read path.

.wc_copied <- function(expr) {
  hit <- FALSE
  real <- garry:::gdal_translate_file
  testthat::local_mocked_bindings(
    gdal_translate_file = function(...) {
      hit <<- TRUE
      real(...)
    },
    .package = "garry"
  )
  force(expr)
  hit
}

.wc_cells <- function(path) {
  ds <- methods::new(gdalraster::GDALRaster, path, TRUE)
  on.exit(ds$close())
  nx <- ds$getRasterXSize()
  ny <- ds$getRasterYSize()
  lapply(seq_len(ds$getRasterCount()), function(b) ds$read(b, 0L, 0L, nx, ny, nx, ny))
}

local({
  src <- fixture_multiband()$path
  out <- function() tempfile(fileext = ".tif")

  for (distributed in c(FALSE, TRUE)) {
    test_that(paste("a whole file copies, and matches the read path; distributed:", distributed), {
      if (distributed) local_pools(2, 1)
      x <- lazy_dataset(src)
      a <- out()
      expect_true(.wc_copied(write_tif(x, a, distributed = distributed)))
      b <- out()
      testthat::local_mocked_bindings(.copy_args = function(...) NULL, .package = "garry")
      expect_false(.wc_copied(write_tif(x, b, distributed = distributed)))
      expect_identical(.wc_cells(a), .wc_cells(b))
      da <- methods::new(gdalraster::GDALRaster, a, TRUE)
      db <- methods::new(gdalraster::GDALRaster, b, TRUE)
      withr::defer({ da$close(); db$close() })
      expect_identical(da$getRasterCount(), db$getRasterCount())
      expect_identical(da$getProjection(), db$getProjection())
      expect_identical(da$getGeoTransform(), db$getGeoTransform())
      expect_identical(da$getBlockSize(1L), db$getBlockSize(1L))
      expect_identical(da$getMetadataItem(0L, "COMPRESSION", "IMAGE_STRUCTURE"), "DEFLATE")
      expect_identical(
        vapply(seq_len(da$getRasterCount()), da$getDescription, ""),
        vapply(seq_len(db$getRasterCount()), db$getDescription, "")
      )
    })
  }

  test_that("a change to the cells or the grid takes the read path", {
    x <- lazy_dataset(src)
    half <- grid_spec("EPSG:32632", extent = c(500000, 4599600, 500300, 4600000), dims = c(30L, 40L))
    expect_false(.wc_copied(write_tif(lazy_dataset(src, grid = half), out())))
    expect_false(.wc_copied(write_tif(x, out(), dtype = "f64")))
    expect_false(.wc_copied(write_tif(x, out(), nodata = -1)))
    expect_false(.wc_copied(materialise(list(a = lazy_source(src)), withr::local_tempdir(), name = "m")))
  })

  test_that("an integer file copies only with its own nodata", {
    i16 <- lazy_dataset(fixture_i16_nodata())
    expect_true(.wc_copied(write_tif(i16, out(), dtype = "i16", nodata = -9999)))
    expect_false(.wc_copied(write_tif(i16, out(), dtype = "i16", nodata = -1)))
  })

  test_that("a file's own sentinel keeps it from the copy", {
    # a declared grid leaves the node without the sentinel a read still masks
    declared <- function(f) lazy_source(f, grid = gdal_grid_spec(f)$grid)
    f32 <- fixture_tile(c(-9999, 7), nodata = -9999)
    a <- out()
    expect_false(.wc_copied(write_tif(declared(f32), a)))
    b <- out()
    write_tif(lazy_source(f32), b)
    expect_identical(.wc_cells(a), .wc_cells(b))
    expect_false(-9999 %in% .wc_cells(a)[[1L]])

    i16 <- fixture_tile(c(-9999, 7), "Int16", nodata = -9999)
    a <- out()
    expect_false(.wc_copied(write_tif(declared(i16), a, nodata = -1)))
    ds <- methods::new(gdalraster::GDALRaster, a, TRUE)
    withr::defer(ds$close())
    expect_identical(ds$getNoDataValue(1L), -1)
    expect_identical(sum(is.na(.wc_cells(a)[[1L]])), 8L)

    # that sentinel kept as it is, or none at all, still copies
    expect_true(.wc_copied(write_tif(declared(i16), out(), nodata = -9999)))
    expect_true(.wc_copied(write_tif(lazy_source(fixture_tile(c(1, 7), "Int16")), out())))
  })

  test_that("a float's NaN cells take the output's nodata", {
    f <- fixture_tile(c(NaN, 1, 2, 3))
    got <- out()
    write_tif(lazy_dataset(f), got, nodata = -1)
    v <- .wc_cells(got)[[1L]] # GDAL reads a nodata cell as NA, and a NaN as NaN
    expect_identical(sum(is.na(v)), 4L)
    expect_false(any(is.nan(v)))
  })
})
