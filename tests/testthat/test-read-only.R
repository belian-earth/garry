# The read-only route copies plans that only read and stack rasters from
# GDAL straight into the result. It must match the compute path exactly,
# result attributes included.

.ro_both <- function(build) {
  withr::local_options(garry.chunk_target_px = 400)
  withr::local_options(garry.read_only = TRUE)
  fast <- collect(build(), distributed = FALSE)
  route <- garry_last_route()
  withr::local_options(garry.read_only = FALSE)
  slow <- collect(build(), distributed = FALSE)
  list(fast = fast, slow = slow, route = route)
}

test_that("a single source takes the read-only route, chunked", {
  r <- .ro_both(function() lazy_source(fixture_gradient_f32()))
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
  expect_equal(
    unclass(r$fast)[1:2, 1:2],
    .fixture_values(60, 40)[1:2, 1:2],
    ignore_attr = TRUE
  )
})

test_that("integer nodata reads as NaN on the read-only route", {
  r <- .ro_both(function() lazy_source(fixture_i16_nodata()))
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
  expect_true(is.nan(r$fast[1, 1]))
})

test_that("a band stack of sources matches the compute path", {
  mb <- fixture_multiband()
  r <- .ro_both(function() {
    g <- graph_new()
    lazy_stack(
      lapply(c(1L, 4L, 2L), function(b) {
        lazy_source(mb$path, band = b, graph = g)
      }),
      along = "band"
    )
  })
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
  expect_identical(dim(r$fast), c(40L, 60L, 3L))
})

test_that("coalesced same-file bands match the compute path", {
  mb <- fixture_multiband()
  f <- fixture_gradient_f32()
  r <- .ro_both(function() {
    g <- graph_new()
    lazy_stack(
      list(
        lazy_source(f, graph = g),
        lazy_source(mb$path, band = 5L, graph = g),
        lazy_source(mb$path, band = 3L, graph = g)
      ),
      along = "band"
    )
  })
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
  expect_identical(dim(r$fast), c(40L, 60L, 3L))
  expect_equal(r$fast[,, 2], mb$vals[[5]], tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a time stack matches the compute path", {
  f <- fixture_gradient_f32()
  r <- .ro_both(function() {
    g <- graph_new()
    lazy_stack(
      list(
        lazy_source(f, graph = g),
        lazy_source(fixture_random_f32(), graph = g, grid = lazy_source(f)@grid)
      ),
      along = "t"
    )
  })
  expect_identical(r$fast, r$slow)
})

test_that("a sub-grid crop matches the compute path", {
  f <- fixture_gradient_f32()
  sub <- grid_spec(
    crs = "EPSG:32632",
    extent = c(500100, 4599700, 500450, 4599950),
    res = 10
  )
  r <- .ro_both(function() lazy_source(f, grid = sub))
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
  expect_identical(dim(r$fast), c(25L, 35L))
})

test_that("a warped stack (downsample) matches the compute path", {
  f <- fixture_i16_nodata()
  coarse <- grid_spec(
    crs = "EPSG:32632",
    extent = c(400000, 4499000, 401400, 4500000),
    res = 60
  )
  r <- .ro_both(function() {
    g <- graph_new()
    lazy_stack(
      list(
        align_to(lazy_source(f, graph = g), coarse, resampling = "average"),
        align_to(lazy_source(f, graph = g), coarse, resampling = "near")
      ),
      along = "band"
    )
  })
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
})

test_that("plans that compute leave the read-only route", {
  f <- fixture_gradient_f32()
  collect(lazy_source(f) * 2, distributed = FALSE)
  expect_false(identical(garry_last_route(), "read_only"))
  collect(
    focal_map(lazy_source(f), radius = 1L, fn = function(sh) {
      Reduce(`+`, sh) / 9
    }),
    distributed = FALSE
  )
  expect_false(identical(garry_last_route(), "read_only"))
})

.ro_write_both <- function(build, ...) {
  withr::local_options(garry.chunk_target_px = 400)
  fast <- withr::local_tempfile(fileext = ".tif")
  slow <- withr::local_tempfile(fileext = ".tif")
  withr::local_options(garry.read_only = TRUE)
  write_tif(build(), fast, ..., distributed = FALSE)
  route <- garry_last_route()
  withr::local_options(garry.read_only = FALSE)
  write_tif(build(), slow, ..., distributed = FALSE)
  rd <- function(f) {
    ds <- methods::new(gdalraster::GDALRaster, f)
    on.exit(ds$close())
    list(
      v = lapply(seq_len(ds$getRasterCount()), function(b) {
        ds$read(
          b,
          0,
          0,
          ds$getRasterXSize(),
          ds$getRasterYSize(),
          ds$getRasterXSize(),
          ds$getRasterYSize()
        )
      }),
      dt = ds$getDataTypeName(1L),
      nd = ds$getNoDataValue(1L),
      desc = vapply(
        seq_len(ds$getRasterCount()),
        ds$getDescription,
        character(1)
      ),
      gt = ds$getGeoTransform()
    )
  }
  list(fast = rd(fast), slow = rd(slow), route = route)
}

test_that("a read-only write matches the compute path's file", {
  f <- fixture_i16_nodata()
  mb <- fixture_multiband()
  stk <- function() {
    g <- graph_new()
    lazy_stack(
      list(a = lazy_source(f, graph = g), b = lazy_source(f, graph = g)),
      along = "band"
    )
  }
  r <- .ro_write_both(stk)
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
  r <- .ro_write_both(
    stk,
    dtype = "i16",
    nodata = -9999,
    creation_options = c("COMPRESS=LZW", "TILED=YES")
  )
  expect_identical(r$fast, r$slow)
  expect_identical(r$fast$dt, "Int16")
  r <- .ro_write_both(
    function() {
      g <- graph_new()
      lazy_stack(
        lapply(c(2L, 6L), function(b) {
          lazy_source(mb$path, band = b, graph = g)
        }),
        along = "band"
      )
    },
    dtype = "u16",
    scale = 0.1,
    nodata = 0
  )
  expect_identical(r$route, "read_only")
  expect_identical(r$fast, r$slow)
})

test_that("the read pool serves the read-only route with identical results", {
  skip_on_cran()
  local_pools(2, 1)
  withr::local_options(garry.chunk_target_px = 400)
  mb <- fixture_multiband()
  f <- fixture_i16_nodata()
  coarse <- grid_spec(
    crs = "EPSG:32632",
    extent = c(400000, 4499000, 401400, 4500000),
    res = 60
  )
  plans <- list(
    function() {
      g <- graph_new()
      lazy_stack(
        list(
          lazy_source(fixture_gradient_f32(), graph = g),
          lazy_source(mb$path, band = 5L, graph = g),
          lazy_source(mb$path, band = 3L, graph = g)
        ),
        along = "band"
      )
    },
    function() {
      g <- graph_new()
      lazy_stack(
        list(
          align_to(lazy_source(f, graph = g), coarse, resampling = "average"),
          align_to(lazy_source(f, graph = g), coarse)
        ),
        along = "band"
      )
    },
    function() lazy_source(f)
  )
  for (build in plans) {
    pooled <- collect(build(), distributed = TRUE)
    expect_identical(garry_last_route(), "read_only")
    withr::with_options(list(garry.read_only = FALSE), {
      ref <- collect(build(), distributed = FALSE)
    })
    expect_identical(pooled, ref)
  }
  out <- withr::local_tempfile(fileext = ".tif")
  ref <- withr::local_tempfile(fileext = ".tif")
  write_tif(
    plans[[2]](),
    out,
    dtype = "i16",
    nodata = -9999,
    distributed = TRUE
  )
  expect_identical(garry_last_route(), "read_only")
  withr::with_options(list(garry.read_only = FALSE), {
    write_tif(
      plans[[2]](),
      ref,
      dtype = "i16",
      nodata = -9999,
      distributed = FALSE
    )
  })
  rd <- function(p) {
    ds <- methods::new(gdalraster::GDALRaster, p)
    on.exit(ds$close())
    nx <- ds$getRasterXSize()
    ny <- ds$getRasterYSize()
    lapply(1:2, function(b) ds$read(b, 0, 0, nx, ny, nx, ny))
  }
  expect_identical(rd(out), rd(ref))
})
