# The read-only route copies plans that only read and stack rasters from
# GDAL straight into the result. It must match the compute path exactly,
# result attributes included.

.ro_both <- function(build) {
  withr::local_options(garry.chunk_target_px = 400, garry.read_target_px = 400)
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
  expect_identical(r$route, "read_only")
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
  withr::local_options(garry.chunk_target_px = 400, garry.read_target_px = 400)
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

test_that("a threaded read gives GDAL_NUM_THREADS back, even when it fails", {
  threads <- function() gdalraster::get_config_option("GDAL_NUM_THREADS")
  gdalraster::set_config_option("GDAL_NUM_THREADS", "2")
  withr::defer(gdalraster::set_config_option("GDAL_NUM_THREADS", ""))
  f <- fixture_gradient_f32()
  restore <- garry:::.gdal_threads_all(f)
  expect_identical(threads(), "ALL_CPUS")
  restore()
  expect_identical(threads(), "2")
  # worker threads must not report from a Zarr read
  garry:::.gdal_threads_all("store.zarr")
  expect_identical(threads(), "2")
  x <- lazy_source(f)
  expect_no_error(collect(x, distributed = FALSE))
  expect_identical(garry_last_route(), "read_only")
  expect_identical(threads(), "2")
  testthat::local_mocked_bindings(
    .exec_read_padded = function(...) stop("read failed"),
    .package = "garry"
  )
  expect_error(collect(x, distributed = FALSE), "read failed")
  expect_identical(threads(), "2")
})

# A skip here ends the file, so this block stays last.
test_that("a read-only plan grows a single-band file's chunks to one task", {
  tif <- function(nx, ny, block, bands = 1L) {
    f <- withr::local_tempfile(fileext = ".tif", .local_envir = parent.frame(2))
    opts <- if (block[[1L]] < nx) {
      c("TILED=YES", paste0("BLOCKXSIZE=", block[[1L]]), paste0("BLOCKYSIZE=", block[[2L]]))
    } else {
      paste0("BLOCKYSIZE=", block[[2L]])
    }
    ds <- gdalraster::create("GTiff", f, nx, ny, bands, "Float32", options = opts, return_obj = TRUE)
    ds$setGeoTransform(c(500000, 30, 0, 5000000, 0, -30))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32633"))
    ds$close()
    f
  }
  chunk_dim <- function(x, target, planned = 400) {
    withr::local_options(garry.chunk_target_px = planned, garry.read_target_px = target)
    .read_only_spec(plan_lazy(x))$read_stage[[1L]]@chunks@chunk_dim
  }
  plan_dim <- function(x, target, planned) {
    withr::local_options(garry.chunk_target_px = planned, garry.read_target_px = target)
    plan_lazy(x)@stages[[1L]]@chunks@chunk_dim
  }
  tiled <- lazy_source(tif(128L, 128L, c(16L, 16L)))
  # a file that fits one task is one chunk, however finely it was planned
  expect_identical(chunk_dim(tiled, 1e6), c(128L, 128L))
  # past that, chunks stay inside the target and end on source tiles
  expect_identical(chunk_dim(tiled, 4000), c(48L, 80L))
  # a strip is full width, so rows pay for it, and a long file still fits whole
  expect_identical(chunk_dim(lazy_source(tif(128L, 64L, c(128L, 1L))), 5000), c(128L, 39L))
  expect_identical(chunk_dim(lazy_source(tif(400L, 20L, c(16L, 16L))), 9000), c(400L, 20L))
  # a block past the target is still one block
  expect_identical(chunk_dim(tiled, 100, 1), c(16L, 16L))
  # a warp's target pixels have no tiles to end on
  g <- grid_spec("EPSG:32634", extent = c(0, 0, 1280, 1280), dims = c(128L, 128L), dtype = "f32")
  expect_identical(chunk_dim(align_to(tiled, g), 4000), c(63L, 63L))
  # a planned chunk at the target stands, and a multi-band one is priced for its bands
  expect_identical(chunk_dim(tiled, 1000, 1e6), plan_dim(tiled, 1000, 1e6))
  f <- tif(128L, 128L, c(16L, 16L), 3L)
  g3 <- graph_new()
  mb <- lazy_stack(lapply(1:3, function(b) lazy_source(f, band = b, graph = g3)), along = "band")
  expect_identical(chunk_dim(mb, 1e9), plan_dim(mb, 1e9, 400))
})

test_that("a pool write reads inside its budget, or to start an idle run", {
  # nothing running: a region past the budget still goes
  expect_true(.read_fits(0L, 0L, 0, 100, 10))
  # queued writes drain the store, so reads wait for them
  expect_false(.read_fits(0L, 3L, 90, 20, 100))
  expect_false(.read_fits(1L, 0L, 70, 20, 100))
  expect_true(.read_fits(1L, 3L, 50, 20, 100))
})

test_that("raw columns keep each row's run of bytes and refuse a bad shape", {
  x <- as.raw(1:24)
  expect_identical(
    .Call("garry_raw_columns", x, 6, 2, 3, PACKAGE = "garry"),
    x[c(3:5, 9:11, 15:17, 21:23)]
  )
  expect_error(.Call("garry_raw_columns", x, 7, 2, 3, PACKAGE = "garry"), "no rows")
  expect_error(.Call("garry_raw_columns", x, 6, 4, 3, PACKAGE = "garry"), "no rows")
})

test_that("a chunk large enough to thread lands exactly where a small one does", {
  ny <- 700L; nx <- 600L; nk <- 3L
  h <- 650L; w <- 550L
  planes <- function(b) (seq_len(h * w) %% 8191) + b / 4
  v <- writeBin(c(planes(1), planes(2)), raw(), size = 4)
  out <- .Call("garry_alloc_double", as.numeric(ny) * nx * nk, PACKAGE = "garry")
  out[] <- -1
  dim(out) <- c(ny, nx, nk)
  .Call(
    "garry_f32_into_colmajor", out, v, as.numeric(c(30, 20, 1)),
    as.numeric(c(ny, nx, nk, 2, h, w)), PACKAGE = "garry"
  )
  want <- array(-1, c(ny, nx, nk))
  for (b in 1:2) {
    want[31:680, 21:570, b + 1L] <- t(matrix(planes(b), w, h))
  }
  expect_identical(out, want)
})

local({
  skip_on_cran()
  local_pools(2, 1)

  test_that("the read pool serves the read-only route with identical results", {
    withr::local_options(garry.chunk_target_px = 400, garry.read_target_px = 400)
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

    # a read that fails on the pool reaches the host, naming the file
    gone <- withr::local_tempfile(fileext = ".tif")
    file.copy(f, gone)
    x <- lazy_source(gone)
    # Windows deletes no file that a handle holds open
    .gdal_handles_release(gone)
    unlink(gone)
    withr::local_options(garry.read_retry = 0L)
    err <- expect_error(collect(x, distributed = TRUE), class = "garry_task_error")
    expect_match(conditionMessage(err), basename(gone), fixed = TRUE)
  })

  test_that("reads the scheduler would fetch stay with the scheduler", {
    gti <- .gg_gti(list(a = .gg_val(0), b = .gg_val(100)))
    build <- function() {
      g <- graph_new()
      lazy_stack(
        list(.gg_slice(gti, "a", g), .gg_slice(gti, "b", g)),
        along = "band"
      )
    }
    ref <- collect(build(), distributed = FALSE)
    # local items: no fetch, so the read pool serves the read-only route
    withr::local_options(garry.fetch = "auto")
    expect_identical(collect(build(), distributed = TRUE), ref)
    expect_identical(garry_last_route(), "read_only")
    # fetched items (forced here; remote ones under "auto") go to the scheduler
    withr::local_options(garry.fetch = "force")
    expect_equal(collect(build(), distributed = TRUE), ref, ignore_attr = TRUE)
    expect_identical(garry_last_route(), "scheduler")
  })
})
