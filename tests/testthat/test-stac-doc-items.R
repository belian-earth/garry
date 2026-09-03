# STAC doc_items as a first-class input: the vrtility-style filters compose on
# the rstac object, and lazy_dataset() converts it to the sources table
# internally. Hand-built doc_items avoid the network.

.di_feat <- function(id, cc, bbox, orbit, hrefs,
                     dt = "2023-06-01T00:00:00Z") {
  list(id = id, collection = "c", bbox = bbox,
       properties = list(datetime = dt, `eo:cloud_cover` = cc,
                         `sat:orbit_state` = orbit, platform = "S2A"),
       assets = lapply(hrefs, function(h) list(href = h)))
}
.di_items <- function(features) {
  structure(list(type = "FeatureCollection", features = features),
            class = c("doc_items", "list"))
}
.di_cog <- function(f, code, nd = -32768L) {
  d <- gdalraster::create("GTiff", f, 64, 64, 1, "Int16", return_obj = TRUE,
                          options = c("TILED=YES", "BLOCKXSIZE=64",
                                      "BLOCKYSIZE=64"))
  d$setGeoTransform(c(0, 10, 0, 640, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  d$setNoDataValue(1, nd)
  d$write(1, 0, 0, 64, 64, rep(code, 64 * 64))
  d$close()
  f
}

test_that("cloud/coverage/orbit filters compose on a doc_items", {
  skip_if_not_installed("rstac")
  its <- .di_items(list(
    .di_feat("a", 10, c(0, 0, 10, 10), "descending", list(B04 = "a.tif")),
    .di_feat("b", 90, c(0, 0, 10, 10), "ascending",  list(B04 = "b.tif")),
    .di_feat("c",  5, c(9, 9, 10, 10), "descending", list(B04 = "c.tif"))))
  expect_length(stac_filter_cloud(its, 50)$features, 2L)             # b drops
  expect_length(stac_filter_coverage(its, c(0, 0, 10, 10), 0.5)$features, 2L)  # c drops
  expect_length(stac_filter_orbit(its, "descending")$features, 2L)  # b drops
  # chained, and dedup on identical bbox/datetime/platform/orbit keeps a vs c
  chained <- its |> stac_filter_cloud(50) |> stac_filter_orbit("descending")
  expect_length(chained$features, 2L)
})

test_that("stac_filter_assets keeps only named assets (doc_items + table)", {
  skip_if_not_installed("rstac")
  its <- .di_items(list(
    .di_feat("a", 5, c(0, 0, 10, 10), "descending",
      list(B04 = "a4.tif", B03 = "a3.tif", Fmask = "af.tif", thumb = "at.png")),
    .di_feat("b", 5, c(0, 0, 10, 10), "descending",
      list(B04 = "b4.tif", thumb = "bt.png"))))     # b lacks B03/Fmask
  kept <- stac_filter_assets(its, c("B04", "B03", "Fmask"))
  expect_setequal(names(kept$features[[1L]]$assets), c("B04", "B03", "Fmask"))
  expect_setequal(names(kept$features[[2L]]$assets), "B04")   # thumb dropped

  # an item with none of the requested assets is dropped entirely, and an
  # asset absent from every item warns
  only_thumb <- .di_items(list(
    .di_feat("c", 5, c(0, 0, 10, 10), "descending", list(thumb = "c.png"))))
  expect_warning(dropped <- stac_filter_assets(only_thumb, "B04"), "not present")
  expect_length(dropped$features, 0L)

  # sources-table branch
  df <- data.frame(asset = c("B04", "B03", "thumb"), datetime = "d",
                   location = "x")
  expect_setequal(stac_filter_assets(df, c("B04", "B03"))$asset,
                  c("B04", "B03"))
})

test_that("stac_rename_assets + stac_merge harmonise across doc_items", {
  skip_if_not_installed("rstac")
  l30 <- .di_items(list(.di_feat("l1", 5, c(0, 0, 10, 10), "descending",
    list(B04 = "l_B04.tif", B05 = "l_B05.tif", Fmask = "l_Fmask.tif"))))
  s30 <- .di_items(list(.di_feat("s1", 5, c(0, 0, 10, 10), "ascending",
    list(B04 = "s_B04.tif", B08 = "s_B08.tif", Fmask = "s_Fmask.tif"))))
  l30r <- stac_rename_assets(l30, c(B04 = "R", B05 = "N2", Fmask = "Fmask"))
  s30r <- stac_rename_assets(s30, c(B04 = "R", B08 = "N", Fmask = "Fmask"))
  expect_setequal(names(l30r$features[[1L]]$assets), c("R", "N2", "Fmask"))
  expect_setequal(names(s30r$features[[1L]]$assets), c("R", "N", "Fmask"))

  merged <- stac_merge(l30r, s30r)
  expect_length(merged$features, 2L)
  bands <- unique(unlist(lapply(merged$features, function(f) names(f$assets))))
  expect_setequal(bands, c("R", "N2", "N", "Fmask"))    # the union, ragged bands
})

test_that("stac_filter_coverage also works on a sources data frame", {
  src <- data.frame(asset = "B04", datetime = "d", location = "x",
                    xmin = c(0, 9), ymin = c(0, 9),
                    xmax = c(10, 10), ymax = c(10, 10))
  expect_equal(nrow(stac_filter_coverage(src, c(0, 0, 10, 10), 0.5)), 1L)
})


test_that("stac_sources() and stac_filter_coverage() reject malformed bboxes", {
  skip_if_not_installed("rstac")
  ok <- .di_feat("a", 10, c(0, 0, 10, 10), "descending", list(B04 = "a.tif"))
  nobox <- ok
  nobox$bbox <- NULL
  nobox$id <- "missing-bbox"
  expect_error(stac_sources(.di_items(list(ok, nobox))), "missing-bbox")
  rev <- ok
  rev$bbox <- c(10, 0, 0, 10)
  expect_error(stac_sources(.di_items(list(rev))), "xmin < xmax")
  expect_error(stac_sources(.di_items(list())), "no features")

  expect_error(
    stac_filter_coverage(.di_items(list(ok, nobox)), c(0, 0, 10, 10)),
    "missing-bbox"
  )
  its <- .di_items(list(ok))
  expect_error(stac_filter_coverage(its, c(0, 0, 0, 10)), "xmin < xmax")
  expect_error(stac_filter_coverage(its, c(0, 0, NA, 10)), "finite")
  expect_error(stac_filter_coverage(its, c(0, 0, 10, 10), 1.5), "min_coverage")
  expect_error(stac_filter_coverage(its, c(0, 0, 10, 10), NA_real_), "min_coverage")
  src <- stac_sources(its)
  expect_error(stac_filter_coverage(src, c(0, 0, 10)), "c\\(xmin, ymin, xmax, ymax\\)")
})
