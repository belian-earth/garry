# grid_from_bbox / grid_from_src: derive an analysis GridSpec from an AOI. The
# default is an equal-area (LAEA) grid centred on the AOI; the extent snaps to
# whole res multiples so dims are integer and the grid is coherent.

bbox_png <- c(144.13, -7.725, 144.47, -7.475)

test_that("grid_from_bbox defaults to a centred equal-area grid", {
  g <- grid_from_bbox(bbox_png, res = 30)
  expect_true(S7::S7_inherits(g, GridSpec))
  expect_match(g@crs, "Lambert_Azimuthal_Equal_Area")   # LAEA, not UTM
  expect_identical(g@dtype, "f32")
  # extent snapped: spans are exact multiples of res, matching integer dims
  expect_equal((g@extent[3] - g@extent[1]) / 30, unname(g@dims[["x"]]))
  expect_equal((g@extent[4] - g@extent[2]) / 30, unname(g@dims[["y"]]))
})

test_that("projection = 'utm' resolves the correct zone EPSG", {
  g <- grid_from_bbox(bbox_png, res = 30, projection = "utm")
  # lon 144, lat -7 -> UTM zone 55 south -> EPSG:32755
  expect_match(g@crs, "32755")
})

test_that("res accepts c(xres, yres) and buffer pads the extent", {
  g1 <- grid_from_bbox(bbox_png, res = 30)
  g2 <- grid_from_bbox(bbox_png, res = c(30, 60))
  expect_equal((g2@extent[4] - g2@extent[2]) / 60, unname(g2@dims[["y"]]))

  gb <- grid_from_bbox(bbox_png, res = 30, buffer = 300)
  expect_gt(gb@dims[["x"]], g1@dims[["x"]])
  expect_gt(gb@dims[["y"]], g1@dims[["y"]])
})

test_that("grid_from_src reads an AOI file and matches the bbox path", {
  poly <- sprintf(
    '{"type":"FeatureCollection","features":[{"type":"Feature","properties":{},
      "geometry":{"type":"Polygon","coordinates":[[[%f,%f],[%f,%f],[%f,%f],[%f,%f],[%f,%f]]]}}]}',
    bbox_png[1], bbox_png[2], bbox_png[3], bbox_png[2], bbox_png[3], bbox_png[4],
    bbox_png[1], bbox_png[4], bbox_png[1], bbox_png[2])
  f <- tempfile(fileext = ".geojson")
  writeLines(poly, f)

  g_src  <- grid_from_src(f, res = 30)
  g_bbox <- grid_from_bbox(bbox_png, res = 30)
  expect_equal(g_src@extent, g_bbox@extent, tolerance = 1e-6)
  expect_equal(unname(g_src@dims), unname(g_bbox@dims))
})

test_that("grid_from_src on a raster keeps its native CRS at the given res", {
  f <- tempfile(fileext = ".tif")
  d <- gdalraster::create("GTiff", f, 512, 512, 1, "Int16", return_obj = TRUE)
  d$setGeoTransform(c(510000, 10, 0, 8555360, 0, -10))   # 10 m native, UTM 36S
  d$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
  d$close()

  g <- grid_from_src(f, res = 30)                         # coarsen in place
  expect_true(crs_equal(g@crs, "EPSG:32736"))             # native CRS, not LAEA
  expect_equal(unname(res(g)), c(30, 30))
  # native extent (5120 m span) snapped out to whole 30 m multiples; dims match
  expect_equal(g@extent[1], 510000)
  expect_equal(g@extent[3], 510000 + ceiling(5120 / 30) * 30)
  expect_equal(unname(g@dims[["x"]]), as.integer((g@extent[3] - g@extent[1]) / 30))
  expect_equal(unname(g@dims[["y"]]), as.integer((g@extent[4] - g@extent[2]) / 30))
})

test_that("a degenerate bbox is rejected", {
  expect_error(grid_from_bbox(c(1, 2, 1, 3), res = 30), "bbox")
  expect_error(grid_from_bbox(bbox_png, res = -5), "res")
})
