# Phase 12: fetch/assemble split. Gates: fetch-backed distributed
# reads are identical to direct reads; "auto" leaves local sources
# alone; the tmpfs cache cleans up. test-failure-routes.R holds a failed
# fetch to its error.

# Slice `i` of the fixture, in plain R: noise above `i`, so the median of
# slices 1, 2 and 3 is slice 2.
.fa_values <- function(i) {
  set.seed(i)
  matrix(runif(60 * 40) + i, 40, 60)
}

.fa_fixture <- function(dir, n_slices = 3L) {
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400),
                    dims = c(60L, 40L), dtype = "f32")
  entries <- do.call(rbind, lapply(seq_len(n_slices), function(i) {
    f <- file.path(dir, sprintf("tile%d.tif", i))
    ds <- garry:::gdal_create_output(f, grid, nodata = numeric(0))
    garry:::gdal_write_window(ds, 0L, 0L, .fa_values(i),
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

# 100 x 100 cells of 10 m over (0, 0)-(1000, 1000), rows from the north in
# `values`, stored north-up or south-up.
.fa_tile <- function(dir, name, values, south_up = FALSE) {
  f <- file.path(dir, name)
  ds <- gdalraster::create("GTiff", f, 100L, 100L, 1L, "Float32", return_obj = TRUE)
  ds$setGeoTransform(if (south_up) c(0, 10, 0, 0, 0, 10) else c(0, 10, 0, 1000, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  stored <- if (south_up) values[100:1, ] else values
  ds$write(1L, 0L, 0L, 100L, 100L, as.numeric(t(stored)))
  ds$close()
  f
}

test_that("a south-up tile fetches the rows of its window", {
  dir <- withr::local_tempdir("fa")
  v <- outer(1:100, 1:100, function(r, c) r * 1000 + c)
  north <- .fa_tile(dir, "north.tif", v)
  south <- .fa_tile(dir, "south.tif", v, south_up = TRUE)
  fetched <- function(f, window) {
    out <- tempfile(fileext = ".tif", tmpdir = dir)
    gdal_fetch_window(f, out, window, "EPSG:3857")
    ds <- methods::new(gdalraster::GDALRaster, out, read_only = TRUE)
    on.exit(ds$close())
    nx <- ds$getRasterXSize()
    ny <- ds$getRasterYSize()
    gt <- ds$getGeoTransform()
    m <- matrix(ds$read(1L, 0L, 0L, nx, ny, nx, ny), ny, nx, byrow = TRUE)
    list(
      dims = c(nx, ny),
      north = if (gt[[6L]] > 0) gt[[4L]] + ny * gt[[6L]] else gt[[4L]],
      cells = if (gt[[6L]] > 0) m[ny:1, ] else m
    )
  }
  # 40 rows, wider than the margins on both sides; 12 rows, narrower than them
  for (w in list(c(200, 300, 600, 700), c(200, 300, 600, 420))) {
    expect_identical(fetched(south, w), fetched(north, w))
  }
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

local({
  local_pools(2, 1, gdal_config = TRUE)

  test_that("fetch-backed distributed reads match direct reads", {
    dir <- withr::local_tempdir("fa")
    fx <- .fa_fixture(dir)
    expect_true(file.exists(paste0(fx$idx, ".meta.rds")))

    p <- plan_lazy(.fa_stack(fx))
    want <- .as_f32(.fa_values(2L))
    expect_equal(execute_plan(p), want, tolerance = 1e-12, ignore_attr = TRUE)

    # a fetch run writes its local index into its own fetch directory
    made <- character(0)
    real <- garry:::gti_index_create
    testthat::local_mocked_bindings(
      gti_index_create = function(entries, path, ...) {
        made <<- c(made, path)
        real(entries, path, ...)
      },
      .package = "garry"
    )
    tlog <- tempfile(fileext = ".csv")
    withr::local_options(garry.fetch = "force", garry.task_log = tlog,
                         garry.chunk_target_px = 400)
    got <- execute_plan_mirai(p)
    expect_equal(got, want, tolerance = 1e-12, ignore_attr = TRUE)

    # fetch tasks actually ran (one per tile), before their assembles
    tl <- read.csv(tlog)
    fkeys <- unique(tl$key[grepl("^f\\d+_", tl$key)])
    expect_identical(length(fkeys), nrow(fx$entries))
    # cache cleaned up (fetch root removed on exit)
    root <- unique(dirname(dirname(made)))
    expect_length(root, 1L)
    expect_match(basename(root), "^garry-fetch-")
    expect_false(dir.exists(root))

    # auto mode: local locations -> no fetch tasks
    tlog2 <- tempfile(fileext = ".csv")
    withr::local_options(garry.fetch = "auto", garry.task_log = tlog2)
    got2 <- execute_plan_mirai(p)
    expect_equal(got2, want, tolerance = 1e-12, ignore_attr = TRUE)
    tl2 <- read.csv(tlog2)
    expect_false(any(grepl("^f\\d+_", tl2$key)))
  })

  test_that("a fetched south-up tile reads as the tile does", {
    dir <- withr::local_tempdir("fa")
    f <- .fa_tile(dir, "south.tif", outer(1:100, 1:100, function(r, c) r * 1000 + c), south_up = TRUE)
    idx <- file.path(dir, "south.gti.fgb")
    gti_index_create(
      data.frame(location = f, slice = "a", datetime = "2020-01-01", xmin = 0, ymin = 0, xmax = 1000, ymax = 1000),
      idx,
      crs = "EPSG:3857"
    )
    for (dims in list(c(40L, 40L), c(40L, 12L))) {
      g <- grid_spec("EPSG:3857", extent = c(200, 700 - dims[[2L]] * 10, 600, 700), dims = dims, dtype = "f32")
      x <- lazy_source(
        paste0("GTI:", idx),
        open_options = gti_open_options(g, filter = "slice = 'a'", sort_field = "datetime"),
        grid = g,
        block_dim = dims
      )
      y <- lazy_map(x, fn = function(a) a + 1)
      want <- collect(y, distributed = FALSE)
      expect_false(anyNA(want))
      withr::with_options(list(garry.fetch = "force"), {
        expect_identical(collect(y, distributed = TRUE), want)
      })
    }
  })

  test_that("two stages sharing fetched files both read them", {
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
    want <- .as_f32(.fa_values(1L)) * 3
    expect_equal(collect(expr, distributed = FALSE), want, tolerance = 1e-6, ignore_attr = TRUE)
    withr::local_options(garry.fetch = "force", garry.chunk_target_px = 400)
    got <- collect(expr, distributed = TRUE)
    expect_equal(got, want, tolerance = 1e-6, ignore_attr = TRUE)
    expect_false(anyNA(got))
  })
})
