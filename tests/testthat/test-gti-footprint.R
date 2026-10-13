# GTI footprint padding. GDAL >= 3.12.3 silently drops a reprojected tile
# when its GDALWarp extent is not inside the index footprint but its
# 4-corner reprojection is (the reads come back all nodata). Gates: a
# geographic tile read onto a projected grid through lazy_dataset() matches
# a plain gdalwarp of the same file, single-process and pooled with both
# fetch modes; the written footprints are padded supersets.

# A smooth EPSG:4326 tile (0.001 deg, 400 x 400) with a declared nodata.
.geo_tile <- function(dir) {
  f <- file.path(dir, "geo.tif")
  ds <- gdalraster::create("GTiff", f, 400, 400, 1, "Float32",
                           options = "TILED=YES", return_obj = TRUE)
  ds$setGeoTransform(c(14.6, 0.001, 0, 2.3, 0, -0.001))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:4326"))
  ds$setNoDataValue(1, -9999)
  ds$write(1, 0, 0, 400, 400, as.numeric(outer(1:400, 1:400, "+")))
  ds$close()
  f
}

.geo_sources <- function(f) {
  stac_time_slices(data.frame(
    location = f, asset = "v", datetime = "2026-01-14T17:00:00Z",
    cloud_cover = NA_real_, xmin = 14.6, ymin = 1.9, xmax = 15.0, ymax = 2.3
  ), "day")
}

# gdalwarp of the tile onto `grid`, nearest: the oracle.
.geo_oracle <- function(f, grid) {
  out <- tempfile(fileext = ".tif")
  gdalraster::warp(f, out, t_srs = grid@crs, cl_arg = c(
    "-te", grid@extent, "-ts", grid@dims[["x"]], grid@dims[["y"]],
    "-r", "near", "-q"
  ))
  r <- methods::new(gdalraster::GDALRaster, out)
  on.exit(r$close())
  v <- r$read(1, 0, 0, grid@dims[["x"]], grid@dims[["y"]],
              grid@dims[["x"]], grid@dims[["y"]])
  v[is.na(v)] <- NaN
  matrix(v, grid@dims[["y"]], grid@dims[["x"]], byrow = TRUE)
}

.expect_matches_oracle <- function(got, want) {
  expect_identical(dim(got), dim(want))
  expect_lt(mean(is.nan(got)), 0.01)
  ok <- !is.nan(got) & !is.nan(want)
  # GTI aligns its warped tile to the target grid in two passes, so the
  # odd edge pixel picks the neighbouring source cell: compare in bulk
  expect_gt(mean(abs(got[ok] - want[ok]) <= 2), 0.99)
}

test_that("a geographic tile reads onto a projected grid", {
  dir <- withr::local_tempdir("gfp")
  f <- .geo_tile(dir)
  grid <- grid_from_bbox(c(14.65, 1.95, 14.85, 2.15), res = 100,
                         projection = "utm")
  x <- lazy_dataset(.geo_sources(f), grid, assets = "v")@bands$v[[1L]]
  .expect_matches_oracle(
    unclass(collect(x, distributed = FALSE))[, ],
    .geo_oracle(f, grid)
  )
})

test_that("pooled reads of a geographic tile match, fetched or direct", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  dir <- withr::local_tempdir("gfp")
  f <- .geo_tile(dir)
  grid <- grid_from_bbox(c(14.65, 1.95, 14.85, 2.15), res = 100,
                         projection = "utm")
  x <- lazy_dataset(.geo_sources(f), grid, assets = "v")@bands$v[[1L]]
  want <- .geo_oracle(f, grid)
  local_pools(2, 1)
  for (mode in c("force", "direct")) {
    withr::with_options(list(garry.fetch = mode), {
      .expect_matches_oracle(unclass(collect(x))[, ], want)
    })
  }
})

test_that("stac_gti_index pads each footprint by 1% of its span", {
  dir <- withr::local_tempdir("gfp")
  src <- .geo_sources(file.path(dir, "geo.tif"))
  idx <- stac_gti_index(src, "v", path = file.path(dir, "i.gti.fgb"))
  e <- readRDS(paste0(idx, ".meta.rds"))$entries
  expect_equal(c(e$xmin, e$ymin, e$xmax, e$ymax),
               c(14.596, 1.896, 15.004, 2.304))
})
