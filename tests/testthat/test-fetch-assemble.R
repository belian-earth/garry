# Phase 12: fetch/assemble split. Gates: fetch-backed distributed
# reads are identical to direct reads; "auto" leaves local sources
# alone; a failed fetch aborts the run, naming the object; the tmpfs
# cache cleans up.


.fa_fixture <- function(dir, n_slices = 3L) {
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400),
                    dims = c(60L, 40L), dtype = "f32")
  entries <- do.call(rbind, lapply(seq_len(n_slices), function(i) {
    f <- file.path(dir, sprintf("tile%d.tif", i))
    ds <- garry:::gdal_create_output(f, grid, nodata = numeric(0))
    set.seed(i)
    garry:::gdal_write_window(ds, 0L, 0L,
                              matrix(runif(60 * 40) + i, 40, 60),
                              dtype = "f32", nodata = numeric(0))
    ds$close()
    data.frame(location = f, datetime = sprintf("2023-01-%02d", i),
               slice = sprintf("2023-01-%02d", i),
               xmin = 0, ymin = 0, xmax = 600, ymax = 400)
  }))
  idx <- file.path(dir, "fa.gti.fgb")
  gti_index_create(entries, idx, crs = "EPSG:3857")
  list(grid = grid, idx = idx, entries = entries)
}

.fa_stack <- function(fx) {
  slices <- fx$entries$slice
  layers <- lapply(slices, function(sl) {
    lazy_source(paste0("GTI:", fx$idx),
                open_options = gti_open_options(
                  fx$grid, filter = sprintf("slice = '%s'", sl),
                  sort_field = "datetime"))
  })
  reduce_over(lazy_stack(layers), "median", "t", nan_rm = TRUE)
}

test_that("fetch-backed distributed reads match direct reads", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  dir <- withr::local_tempdir("fa")
  fx <- .fa_fixture(dir)
  expect_true(file.exists(paste0(fx$idx, ".meta.rds")))

  expr <- .fa_stack(fx)
  p <- plan_lazy(expr)
  direct <- execute_plan(p)

  local_pools(2, 1, gdal_config = TRUE)

  tlog <- tempfile(fileext = ".csv")
  old <- options(garry.fetch = "force", garry.task_log = tlog,
                 garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  got <- execute_plan_mirai(p)
  expect_equal(got, direct, tolerance = 1e-12)

  # fetch tasks actually ran (one per tile), before their assembles
  tl <- read.csv(tlog)
  fkeys <- unique(tl$key[grepl("^f\\d+_", tl$key)])
  expect_identical(length(fkeys), nrow(fx$entries))
  # cache cleaned up (fetch root removed on exit)
  expect_identical(length(list.files("/dev/shm",
                                     pattern = "^garry-fetch-")), 0L)

  # auto mode: local locations -> no fetch tasks
  tlog2 <- tempfile(fileext = ".csv")
  options(garry.fetch = "auto", garry.task_log = tlog2)
  got2 <- execute_plan_mirai(p)
  expect_equal(got2, direct, tolerance = 1e-12)
  tl2 <- read.csv(tlog2)
  expect_false(any(grepl("^f\\d+_", tl2$key)))
})

test_that("a failed fetch aborts the run, naming the object", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  dir <- withr::local_tempdir("fa2")
  fx <- .fa_fixture(dir, n_slices = 2L)

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.fetch = "force", garry.read_retry = 0L,
                 garry.chunk_target_px = 1e6)
  on.exit(options(old), add = TRUE)

  layers <- lapply(fx$entries$slice, function(sl) {
    lazy_source(paste0("GTI:", fx$idx), nodata = -9999,
                open_options = gti_open_options(
                  fx$grid, filter = sprintf("slice = '%s'", sl),
                  sort_field = "datetime"))
  })
  p <- plan_lazy(lazy_stack(layers))
  # the object vanishes AFTER planning (expired token / deleted blob)
  unlink(fx$entries$location[[2L]])
  err <- expect_error(execute_plan_mirai(p), class = "garry_task_error")
  expect_match(conditionMessage(err), "fetch failed", fixed = TRUE)
  expect_match(conditionMessage(err), "tile2.tif", fixed = TRUE)
  # GDAL's own cause and the daemon's class cross with it
  expect_match(conditionMessage(err), "No such file or directory", fixed = TRUE)
  expect_s3_class(err, "garry_read_error")
})

test_that("a tile off the grid fetches nothing a warp could use", {
  dir <- withr::local_tempdir("fa")
  fx <- .fa_fixture(dir, n_slices = 1L)
  out <- file.path(dir, "off.tif")
  # 600 m wide at 10 m a pixel: far past the fetch margin
  garry:::gdal_fetch_window(fx$entries$location[[1L]], out, c(5000, 5000, 5100, 5100), "EPSG:3857")
  ds <- methods::new(gdalraster::GDALRaster, out, read_only = TRUE)
  withr::defer(ds$close())
  expect_equal(c(ds$getRasterXSize(), ds$getRasterYSize()), c(1, 1))
})

test_that("gdal_fetch_window decimates to the target resolution via overviews", {
  # Checkerboard: native pixels 0/1; the AVERAGE overview is ~0.5. A coarse
  # fetch (out_res >> native) must read the overview (uniform), not native.
  n <- 256
  cb <- outer(1:n, 1:n, function(r, c) (r + c) %% 2)
  cog <- tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", cog, n, n, 1, "Float32", return_obj = TRUE,
    options = c("TILED=YES", "BLOCKXSIZE=64", "BLOCKYSIZE=64"))
  ds$setGeoTransform(c(0, 1, 0, n, 0, -1))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, n, n, as.numeric(t(cb))); ds$close()
  d2 <- new(gdalraster::GDALRaster, cog, read_only = FALSE)
  d2$buildOverviews("AVERAGE", levels = c(2, 4, 8), bands = 1); d2$close()

  ext <- c(0, 0, n, n); crs <- gdalraster::srs_to_wkt("EPSG:32632")
  read_out <- function(out_res) {
    o <- tempfile(fileext = ".tif")
    gdal_fetch_window(cog, o, ext, crs, out_res = out_res)
    r <- new(gdalraster::GDALRaster, o); on.exit(r$close())
    nx <- r$getRasterXSize(); ny <- r$getRasterYSize()
    list(nx = nx, sd = sd(r$read(1, 0, 0, nx, ny, nx, ny)))
  }
  coarse <- read_out(out_res = 8)                 # 8x native -> overview
  expect_equal(coarse$nx, 32L)                    # decimated
  expect_lt(coarse$sd, 0.1)                        # uniform: overview, not native

  native <- read_out(out_res = 1)                 # target ~ native -> full res
  expect_equal(native$nx, 256L)
  expect_gt(native$sd, 0.4)                        # checkerboard preserved
})

test_that("two stages sharing fetched files both read them", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  dir <- withr::local_tempdir("fa")
  fx <- .fa_fixture(dir, n_slices = 1L)
  sl <- fx$entries$slice[[1L]]
  src <- function(scale) {
    lazy_source(paste0("GTI:", fx$idx),
                open_options = gti_open_options(
                  fx$grid, filter = sprintf("slice = '%s'", sl),
                  sort_field = "datetime"),
                scale = scale, offset = 0)
  }
  # same index and slice, different affine: two source stages, one fetch
  expr <- src(1) + src(2)
  direct <- collect(expr, distributed = FALSE)
  local_pools(2, 1, gdal_config = TRUE)
  withr::local_options(garry.fetch = "force", garry.chunk_target_px = 400)
  got <- collect(expr, distributed = TRUE)
  expect_equal(got, direct, tolerance = 1e-6, ignore_attr = TRUE)
  expect_false(anyNA(got))
})
