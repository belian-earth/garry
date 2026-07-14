# Decision D18 lock: GTI over a datetime-attributed index is the mosaic
# layer. Gates: mosaic == VRT mosaic; FILTER selects time slices;
# mixed-CRS tiles mosaic onto a pinned grid (impossible with plain VRT);
# SORT_FIELD gives deterministic overlaps; lazy pipelines run on GTI
# sources chunk-invariantly.

skip_if_not_installed("anvl")

# Cut the 60x40 gradient fixture into 2x2 tiles (30x20 each), offset by
# `add`; returns a tile entries data.frame.
.make_tiles <- function(tag, add = 0) {
  src <- fixture_gradient_f32()
  meta <- gdal_grid_spec(src)
  gt <- meta$grid@transform
  entries <- do.call(rbind, lapply(0:3, function(k) {
    tx <- k %% 2L
    ty <- k %/% 2L
    x_off <- tx * 30L; y_off <- ty * 20L
    m <- gdal_read_window(src, 1L, x_off, y_off, 30L, 20L) + add
    f <- file.path(tempdir(), sprintf("garry-gti-%s-%d.tif", tag, k))
    ds <- gdalraster::create("GTiff", f, 30, 20, 1, "Float32",
                             return_obj = TRUE)
    tile_gt <- c(gt[1] + x_off * gt[2], gt[2], 0,
                 gt[4] + y_off * gt[6], 0, gt[6])
    ds$setGeoTransform(tile_gt)
    ds$setProjection(meta$grid@crs)
    ds$write(1, 0, 0, 30, 20, as.numeric(t(m)))
    ds$close()
    data.frame(location = f,
               xmin = tile_gt[1], ymin = tile_gt[4] + 20 * gt[6],
               xmax = tile_gt[1] + 30 * gt[2], ymax = tile_gt[4])
  }))
  entries
}

test_that("GTI mosaic reproduces the source raster and matches VRT", {
  src <- fixture_gradient_f32()
  grid <- gdal_grid_spec(src)$grid
  entries <- .make_tiles("plain")

  idx <- file.path(tempdir(), "garry-gti-plain.gti.gpkg")
  unlink(idx)
  gti_index_create(entries, idx, crs = grid@crs)

  m <- gdal_read_window(paste0("GTI:", idx), 1L, 0L, 0L, 60L, 40L,
                        open_options = gti_open_options(grid))
  want <- gdal_read_window(src, 1L, 0L, 0L, 60L, 40L)
  expect_identical(m, want)

  # VRT reference over the same tiles.
  vrt <- tempfile(fileext = ".vrt")
  gdalraster::buildVRT(vrt, entries$location, quiet = TRUE)
  want_vrt <- gdal_read_window(vrt, 1L, 0L, 0L, 60L, 40L)
  expect_identical(m, want_vrt)
})

test_that("FILTER slices a datetime-attributed index", {
  grid <- gdal_grid_spec(fixture_gradient_f32())$grid
  e1 <- .make_tiles("d1", add = 0)
  e2 <- .make_tiles("d2", add = 1000)
  e1$datetime <- "2023-01-05T00:00:00Z"
  e2$datetime <- "2023-02-05T00:00:00Z"
  idx <- file.path(tempdir(), "garry-gti-time.gti.gpkg")
  unlink(idx)
  gti_index_create(rbind(e1, e2), idx, crs = grid@crs)

  base <- gdal_read_window(fixture_gradient_f32(), 1L, 0L, 0L, 60L, 40L)
  s1 <- gdal_read_window(paste0("GTI:", idx), 1L, 0L, 0L, 60L, 40L,
    open_options = gti_open_options(
      grid, filter = "datetime = '2023-01-05T00:00:00Z'"))
  s2 <- gdal_read_window(paste0("GTI:", idx), 1L, 0L, 0L, 60L, 40L,
    open_options = gti_open_options(
      grid, filter = "datetime = '2023-02-05T00:00:00Z'"))
  expect_identical(s1, base)
  expect_identical(s2, base + 1000)
})

test_that("lazy time slices over one GTI index stack and reduce", {
  grid <- gdal_grid_spec(fixture_gradient_f32())$grid
  idx <- file.path(tempdir(), "garry-gti-time.gti.gpkg")
  skip_if(!file.exists(idx))

  slices <- lapply(c("2023-01-05T00:00:00Z", "2023-02-05T00:00:00Z"),
                   function(d) {
    lazy_source(paste0("GTI:", idx),
                open_options = gti_open_options(
                  grid, filter = sprintf("datetime = '%s'", d)))
  })
  st <- lazy_stack(slices)
  expect_identical(unname(st@grid@dims[["t"]]), 2L)

  old <- options(garry.chunk_target_px = 300)
  on.exit(options(old))
  mn <- collect(reduce_over(st, "mean", "t"))
  base <- gdal_read_window(fixture_gradient_f32(), 1L, 0L, 0L, 60L, 40L)
  expect_equal(mn, base + 500, tolerance = 1e-3, ignore_attr = "gis")
})

test_that("mixed-CRS tiles mosaic onto a pinned grid", {
  # Tile A: the UTM 32N gradient fixture. Tile B: an EPSG:4326 tile
  # covering ground immediately east of A. One GTI index, one pinned
  # 4326 target grid: the driver reprojects per tile (a capability plain
  # VRT lacks: gdalbuildvrt warns and skips heterogeneous-SRS inputs).
  fa <- fixture_gradient_f32()
  ga <- gdal_grid_spec(fa)$grid
  ba <- gdalraster::transform_bounds(ga@extent, ga@crs, "EPSG:4326")

  bb <- c(ba[3], ba[2], ba[3] + (ba[3] - ba[1]), ba[4])   # east neighbour
  fb <- file.path(tempdir(), "garry-gti-4326.tif")
  ds <- gdalraster::create("GTiff", fb, 60, 40, 1, "Float32",
                           return_obj = TRUE)
  gtb <- c(bb[1], (bb[3] - bb[1]) / 60, 0, bb[4], 0,
           -(bb[4] - bb[2]) / 40)
  ds$setGeoTransform(gtb)
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:4326"))
  ds$write(1, 0, 0, 60, 40, rep(7777, 60 * 40))
  ds$setNoDataValue(1, -9999)
  ds$close()

  entries <- data.frame(
    location = c(fa, fb),
    xmin = c(ba[1], bb[1]), ymin = c(ba[2], bb[2]),
    xmax = c(ba[3], bb[3]), ymax = c(ba[4], bb[4]))
  idx <- file.path(tempdir(), "garry-gti-mixed.gti.gpkg")
  unlink(idx)
  gti_index_create(entries, idx, crs = "EPSG:4326")

  union <- c(ba[1], min(ba[2], bb[2]), bb[3], max(ba[4], bb[4]))
  target <- grid_spec("EPSG:4326", extent = union, dims = c(120L, 41L))

  m <- gdal_read_window(paste0("GTI:", idx), 1L, 0L, 0L, 120L, 41L,
                        open_options = gti_open_options(target))

  east <- m[5:35, 70:115]
  expect_gt(mean(east == 7777, na.rm = TRUE), 0.9)
  west <- m[5:35, 5:50]
  expect_gt(mean(west >= 101 & west <= 4060, na.rm = TRUE), 0.9)
})

test_that("SORT_FIELD controls overlap winners deterministically", {
  grid <- gdal_grid_spec(fixture_gradient_f32())$grid
  # Two full-extent single tiles with distinct constant values.
  paths <- vapply(1:2, function(i) {
    f <- file.path(tempdir(), sprintf("garry-gti-ovl-%d.tif", i))
    ds <- gdalraster::create("GTiff", f, 60, 40, 1, "Float32",
                             return_obj = TRUE)
    ds$setGeoTransform(grid@transform)
    ds$setProjection(grid@crs)
    ds$write(1, 0, 0, 60, 40, rep(i * 1000, 60 * 40))
    ds$close()
    f
  }, character(1))
  entries <- data.frame(location = paths,
                        xmin = xmin(grid), ymin = ymin(grid),
                        xmax = xmax(grid), ymax = ymax(grid),
                        prio = c(1, 2))
  idx <- file.path(tempdir(), "garry-gti-ovl.gti.gpkg")
  unlink(idx)
  gti_index_create(entries, idx, crs = grid@crs)

  asc <- gdal_read_window(paste0("GTI:", idx), 1L, 0L, 0L, 60L, 40L,
    open_options = gti_open_options(grid, sort_field = "prio",
                                    sort_asc = TRUE))
  desc <- gdal_read_window(paste0("GTI:", idx), 1L, 0L, 0L, 60L, 40L,
    open_options = gti_open_options(grid, sort_field = "prio",
                                    sort_asc = FALSE))
  expect_true(all(asc == 2000))    # ascending: highest prio drawn last
  expect_true(all(desc == 1000))
})

test_that("lazy pipelines on GTI sources are chunk-invariant", {
  grid <- gdal_grid_spec(fixture_gradient_f32())$grid
  idx <- file.path(tempdir(), "garry-gti-plain.gti.gpkg")
  skip_if(!file.exists(idx))

  a <- lazy_source(paste0("GTI:", idx),
                   open_options = gti_open_options(grid))
  expr <- focal(a * 2, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  run <- function(px) {
    old <- options(garry.chunk_target_px = px)
    on.exit(options(old))
    collect(expr)
  }
  whole <- run(1e6)
  got <- run(13 * 11)
  expect_identical(is.nan(got), is.nan(whole))
  ok <- !is.nan(whole)
  expect_equal(got[ok], whole[ok], tolerance = 1e-7)
})

test_that("GTI reads the matching overview when the pinned grid is
           coarser (gap 6: coarse-target bandwidth)", {
  # Full-res data is 1.0 everywhere; the (single) overview level is
  # overwritten with 2.0 after building, so the value read reveals
  # which level GDAL used. A5-style aggregation workflows depend on
  # this: at coarse target resolution the overview is the difference
  # between reading kilobytes and reading the full-res tile.
  skip_if_not_installed("withr")
  dir <- withr::local_tempdir("gti-ovr")
  src <- file.path(dir, "src.tif")
  ds <- gdalraster::create("GTiff", src, 512, 512, 1, "Float32",
                           return_obj = TRUE)
  ds$setGeoTransform(c(600000, 30, 0, 9200000, 0, -30))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32755"))
  ds$write(1, 0, 0, 512, 512, rep(1.0, 512 * 512))
  ds$close()
  ds <- methods::new(gdalraster::GDALRaster, src, read_only = TRUE)
  ds$buildOverviews("NEAREST", 2L, integer(0))
  ds$close()
  od <- methods::new(gdalraster::GDALRaster, paste0(src, ".ovr"),
                     read_only = FALSE)
  od$write(1, 0, 0, 256, 256, rep(2.0, 256 * 256))
  od$close()

  ext55 <- c(600000, 9200000 - 512 * 30, 600000 + 512 * 30, 9200000)
  mk_index <- function(crs) {
    e <- if (identical(crs, "EPSG:32755")) ext55 else
      gdalraster::transform_bounds(ext55, "EPSG:32755", crs)
    idx <- file.path(dir, paste0(gsub(":", "", crs), ".gti.fgb"))
    gti_index_create(
      data.frame(location = src, datetime = "2023-01-01T00:00:00Z",
                 slice = "2023-01-01", cloud_cover = 0,
                 xmin = e[1], ymin = e[2], xmax = e[3], ymax = e[4]),
      idx, crs = crs)
    idx
  }
  read_mean <- function(idx, grid) {
    mean(gdal_read_window(paste0("GTI:", idx), 1L, 0L, 0L,
                          unname(grid@dims[["x"]]),
                          unname(grid@dims[["y"]]),
                          open_options = gti_open_options(grid)))
  }

  # Same CRS: 2x-coarse pinned grid must hit the overview; the
  # native-res control must not.
  idx55 <- mk_index("EPSG:32755")
  g <- function(crs, ext, n) grid_spec(crs, extent = ext,
                                       dims = c(n, n), dtype = "f32")
  expect_identical(read_mean(idx55, g("EPSG:32755", ext55, 256)), 2)
  expect_identical(read_mean(idx55, g("EPSG:32755", ext55, 512)), 1)

  # Cross-CRS (per-tile warp, the benchmark shape): the warper must
  # also choose the overview.
  idxw <- mk_index("EPSG:3857")
  bb <- gdalraster::transform_bounds(ext55, "EPSG:32755", "EPSG:3857")
  expect_gt(read_mean(idxw, g("EPSG:3857", bb, 256)), 1.9)
  expect_lt(read_mean(idxw, g("EPSG:3857", bb, 512)), 1.1)
})
