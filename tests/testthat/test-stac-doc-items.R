# STAC doc_items as a first-class input: the vrtility-style filters compose on
# the rstac object, and lazy_dataset()/lazy_cog() convert it to the sources table
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

test_that("stac_filter_coverage also works on a sources data frame", {
  src <- data.frame(asset = "B04", datetime = "d", location = "x",
                    xmin = c(0, 9), ymin = c(0, 9),
                    xmax = c(10, 10), ymax = c(10, 10))
  expect_equal(nrow(stac_filter_coverage(src, c(0, 0, 10, 10), 0.5)), 1L)
})

test_that("lazy_cog accepts a doc_items and reads it (internal conversion)", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("cptkirk")
  skip_if_not_installed("rstac")
  dir <- withr::local_tempdir("dicog")
  its <- .di_items(list(.di_feat(
    "s1", 5, c(0, 0, 640, 640), "descending",
    list(A = .di_cog(file.path(dir, "A.tif"), 20L),
         B = .di_cog(file.path(dir, "B.tif"), 50L)))))
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 640, 640),
                    dims = c(16L, 16L), dtype = "f32")
  ds <- lazy_cog(its, grid, assets = c("A", "B"))     # doc_items -> sources table
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_named(ds@bands, c("A", "B"))

  got <- collect(reduce_over(ds, "median", "t", nan_rm = TRUE), distributed = FALSE)
  expect_equal(dim(got), c(16L, 16L, 2L))
  expect_equal(unname(got[1, 1, 1]), 20)
  expect_equal(unname(got[1, 1, 2]), 50)
})
