# Harmonising multi-collection STAC tables (e.g. HLS Landsat + Sentinel-2):
# stac_rename_assets() maps each collection's asset names onto a shared band
# schema, stac_merge() concatenates them, and lazy_dataset() handles the ragged
# result -- a band a collection lacks simply gets fewer slices.

# A files-free source table for the pure table-logic tests.
.hz_tbl <- function(assets, dates = "2023-01-05T00:00:00Z", item = "x") {
  g <- expand.grid(asset = assets, datetime = dates, stringsAsFactors = FALSE)
  data.frame(item_id = item, asset = g$asset,
             location = paste0("/vsimem/", g$asset, ".tif"),
             datetime = g$datetime, cloud_cover = 5,
             xmin = 0, ymin = 0, xmax = 1, ymax = 1, row.names = NULL)
}

test_that("stac_rename_assets maps to common names and drops unmapped by default", {
  src <- .hz_tbl(c("B04", "B05", "B99", "Fmask"))
  out <- stac_rename_assets(src, c(B04 = "R", B05 = "N2", Fmask = "Fmask"))
  expect_setequal(unique(out$asset), c("R", "N2", "Fmask"))   # B99 dropped
  expect_false("B99" %in% out$asset)
})

test_that("stac_rename_assets keeps unmapped assets when asked", {
  src <- .hz_tbl(c("B04", "B99"))
  out <- stac_rename_assets(src, c(B04 = "R"), drop_unmapped = FALSE)
  expect_setequal(unique(out$asset), c("R", "B99"))
})

test_that("stac_rename_assets warns on mapping keys absent from the table", {
  src <- .hz_tbl(c("B04", "Fmask"))
  expect_warning(stac_rename_assets(src, c(B04 = "R", B08 = "N", Fmask = "Fmask")),
                 "B08")
})

test_that("stac_rename_assets rejects an unnamed mapping", {
  expect_error(stac_rename_assets(.hz_tbl("B04"), c("R")), "named character")
})

test_that("stac_merge row-binds harmonised tables and re-sorts", {
  l <- stac_rename_assets(.hz_tbl(c("B04", "B05"), "2023-02-01T00:00:00Z", "L"),
                          c(B04 = "R", B05 = "N2"))
  s <- stac_rename_assets(.hz_tbl(c("B04", "B08"), "2023-01-01T00:00:00Z", "S"),
                          c(B04 = "R", B08 = "N"))
  m <- stac_merge(l, s)
  expect_equal(nrow(m), nrow(l) + nrow(s))
  expect_setequal(unique(m$asset), c("R", "N2", "N"))
  expect_false(is.unsorted(m$datetime))                       # re-sorted by datetime
})

test_that("stac_merge errors on mismatched columns", {
  a <- .hz_tbl("B04"); b <- .hz_tbl("B04"); b$extra <- 1
  expect_error(stac_merge(a, b), "same columns")
})

# -- end to end: two collections, a band present in only one -----------------

# One single-band GeoTIFF per (collection, asset, date); returns a source table.
.hz_collection <- function(coll, dates, assets, base) {
  b <- gdalraster::transform_bounds(c(0, 0, 80, 60), "EPSG:3857", "EPSG:4326")
  rows <- list()
  for (i in seq_along(dates)) for (a in assets) {
    f <- file.path(tempdir(), sprintf("hz-%s-%s-%d.tif", coll, a, i))
    d <- gdalraster::create("GTiff", f, 8, 6, 1, "Float32", return_obj = TRUE)
    d$setGeoTransform(c(0, 10, 0, 60, 0, -10))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    val <- if (a == "QA") 0 else base + i          # QA clear so masking is a no-op
    d$write(1, 0, 0, 8, 6, rep(val, 8 * 6)); d$close()
    rows[[length(rows) + 1L]] <- data.frame(
      item_id = sprintf("%s-%d", coll, i), asset = a, location = f,
      datetime = dates[[i]], cloud_cover = 0,
      xmin = b[[1]], ymin = b[[2]], xmax = b[[3]], ymax = b[[4]], row.names = NULL)
  }
  do.call(rbind, rows)
}

test_that("harmonised HLS-style collections build a ragged dataset that composites", {
  skip_if_not_installed("anvl")
  # "Landsat": R, N2 (narrow NIR), QA over 2 days. "Sentinel": R, N (broad NIR),
  # QA over 2 other days. N is Sentinel-only; N2 is Landsat-only; R is shared.
  L <- stac_rename_assets(
    .hz_collection("L", c("2023-01-05T00:00:00Z", "2023-02-05T00:00:00Z"),
                   c("B04", "B05", "QA"), base = 100),
    c(B04 = "R", B05 = "N2", QA = "Fmask"))
  S <- stac_rename_assets(
    .hz_collection("S", c("2023-03-05T00:00:00Z", "2023-04-05T00:00:00Z"),
                   c("B04", "B08", "QA"), base = 200),
    c(B04 = "R", B08 = "N", QA = "Fmask"))
  src <- stac_merge(L, S)
  expect_setequal(unique(src$asset), c("R", "N2", "N", "Fmask"))

  grid <- gdal_grid_spec(src$location[[1L]])$grid
  ds <- lazy_dataset(src, grid, assets = c("R", "N2", "N"), mask_asset = "Fmask")
  # Ragged bands: R sees all 4 slices, the collection-specific NIRs see 2 each.
  expect_length(ds@bands$R, 4L)
  expect_length(ds@bands$N2, 2L)
  expect_length(ds@bands$N, 2L)

  comp <- collect(reduce_over(mask(ds, where = qa_bits(0)), "median", "t"))
  # QA is 0 (clear), so each band's composite is the median over ITS OWN slices.
  # Value bands, in requested order: R (1), N2 (2), N (3).
  expect_equal(unname(comp[1, 1, 1]), 151.5, tolerance = 1e-4)   # R: 101,102,201,202
  expect_equal(unname(comp[1, 1, 2]), 101.5, tolerance = 1e-4)   # N2: Landsat 101,102
  expect_equal(unname(comp[1, 1, 3]), 201.5, tolerance = 1e-4)   # N: Sentinel 201,202
})
