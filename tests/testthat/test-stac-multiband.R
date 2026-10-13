# Multi-band STAC assets: the table form of lazy_dataset() reads every band
# of an asset that packs several bands into one file (SAR polarisations,
# multi-band land products), each its own dataset band. Gates: default
# naming and band indices, `bands =` selection and renaming, per-band
# nodata keyed by band name or asset, values equal to direct per-band reads
# under both executors, and a failed fetch of a multi-band item degrading
# to a hole in every band.

# Two day slices of a 3-band Float32 asset M (nodata -9999 in the files,
# optional band descriptions) plus a single-band QA asset Q.
.mb_fake_items <- function(dir, descs = NULL) {
  dates <- c("2023-01-05T01:00:00Z", "2023-01-15T01:00:00Z")
  mk <- function(nm, nb, val) {
    f <- file.path(dir, nm)
    ds <- gdalraster::create("GTiff", f, 20, 16, nb, "Float32", return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 160, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    for (b in seq_len(nb)) {
      m <- val(b)
      m[1, 1] <- -9999 # one sentinel pixel per band
      ds$setNoDataValue(b, -9999)
      if (!is.null(descs) && nb > 1L) ds$setDescription(b, descs[[b]])
      ds$write(b, 0, 0, 20, 16, as.numeric(t(m)))
    }
    ds$close()
    f
  }
  b <- gdalraster::transform_bounds(c(0, 0, 200, 160), "EPSG:3857", "EPSG:4326")
  feats <- lapply(1:2, function(i) {
    val <- function(band) outer(1:16, 1:20, function(r, c2) r * 100 + c2) +
      band * 10000 + i * 1000
    list(id = sprintf("item-%d", i), bbox = as.list(b),
         properties = list(datetime = dates[[i]], `eo:cloud_cover` = 10),
         assets = list(
           M = list(href = mk(sprintf("M%d.tif", i), 3L, val)),
           Q = list(href = mk(sprintf("Q%d.tif", i), 1L, function(band) {
             matrix(0, 16, 20)
           }))
         ))
  })
  list(features = feats)
}

.mb_band_of <- function(ds, nm) {
  unique(vapply(ds@bands[[nm]], function(lr) {
    graph_get(lr@graph, lr@node_id)@band
  }, integer(1)))
}

# Direct per-band read of every slice, sentinel -> NaN: the oracle, laid
# out (y, x, t) as collect() returns a multi-slice band.
.mb_direct <- function(src, band) {
  loc <- src$location[src$asset == "M"]
  sl <- lapply(loc, function(f) {
    v <- gdal_read_window(f, band, 0L, 0L, 20L, 16L)
    v[v == -9999] <- NaN
    v
  })
  simplify2array(sl)
}

test_that("a multi-band asset expands to one dataset band per source band", {
  dir <- withr::local_tempdir("mb")
  src <- stac_sources(.mb_fake_items(dir), assets = c("M", "Q"))
  grid <- gdal_grid_spec(src$location[[1]])$grid

  ds <- lazy_dataset(src, grid, assets = "M", mask_asset = "Q")
  expect_identical(names(ds@bands), c("M_b1", "M_b2", "M_b3", "Q"))
  expect_identical(ds@mask_asset, "Q")
  for (b in 1:3) {
    nm <- paste0("M_b", b)
    expect_identical(.mb_band_of(ds, nm), b)
    expect_length(ds@bands[[nm]], 2L)
    got <- collect(ds[[nm]])
    want <- .mb_direct(src, b)
    expect_identical(is.nan(got), is.nan(want))
    expect_equal(got[!is.nan(want)], want[!is.nan(want)])
  }
  expect_identical(.mb_band_of(ds, "Q"), 1L)
})

test_that("band descriptions name the expanded bands", {
  dir <- withr::local_tempdir("mb")
  src <- stac_sources(.mb_fake_items(dir, descs = c("HH", "VH", "VV")),
                      assets = "M")
  grid <- gdal_grid_spec(src$location[[1]])$grid
  ds <- lazy_dataset(src, grid, assets = "M")
  expect_identical(names(ds@bands), c("M_HH", "M_VH", "M_VV"))
})

test_that("bands = selects and renames source bands", {
  dir <- withr::local_tempdir("mb")
  src <- stac_sources(.mb_fake_items(dir), assets = c("M", "Q"))
  grid <- gdal_grid_spec(src$location[[1]])$grid

  ds <- lazy_dataset(src, grid, assets = "M", mask_asset = "Q",
                     bands = list(M = c(hh = 1, vv = 3)))
  expect_identical(names(ds@bands), c("hh", "vv", "Q"))
  expect_identical(.mb_band_of(ds, "vv"), 3L)
  got <- collect(ds[["vv"]])
  want <- .mb_direct(src, 3L)
  expect_equal(got[!is.nan(want)], want[!is.nan(want)])

  # unnamed indices keep the default names
  ds2 <- lazy_dataset(src, grid, assets = "M", bands = list(M = 2))
  expect_identical(names(ds2@bands), "M_b2")
})

test_that("nodata keys by band name before asset; file nodata is per band", {
  dir <- withr::local_tempdir("mb")
  src <- stac_sources(.mb_fake_items(dir), assets = "M")
  grid <- gdal_grid_spec(src$location[[1]])$grid
  nd_of <- function(ds, nm) unique(vapply(ds@bands[[nm]], function(lr) {
    graph_get(lr@graph, lr@node_id)@nodata
  }, numeric(1)))

  ds <- lazy_dataset(src, grid, assets = "M")
  expect_identical(nd_of(ds, "M_b2"), -9999)              # from the file

  ds2 <- lazy_dataset(src, grid, assets = "M",
                      nodata = c(M = -1, M_b2 = -2))
  expect_identical(nd_of(ds2, "M_b1"), -1)                # asset key
  expect_identical(nd_of(ds2, "M_b2"), -2)                # band key wins
})

test_that("bands = is validated in the table form", {
  dir <- withr::local_tempdir("mb")
  src <- stac_sources(.mb_fake_items(dir), assets = c("M", "Q"))
  grid <- gdal_grid_spec(src$location[[1]])$grid
  expect_error(lazy_dataset(src, grid, assets = "M", bands = 1:2),
               "list named by asset")
  expect_error(lazy_dataset(src, grid, assets = "M", mask_asset = "Q",
                            bands = list(Q = 1)),
               "not among the value")
  expect_error(lazy_dataset(src, grid, assets = "M", bands = list(M = 4)),
               "must index 1..3")
  expect_error(lazy_dataset(src, grid, assets = "M",
                            bands = list(M = c(a = 1, a = 2))),
               "repeats a band name")
  expect_error(lazy_dataset(src, grid, assets = c("M", "Q"),
                            bands = list(M = c(Q = 1))),
               "both named")
})

test_that("distributed fetch-backed reads of a multi-band asset match", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  dir <- withr::local_tempdir("mb")
  src <- stac_sources(.mb_fake_items(dir), assets = "M")
  grid <- gdal_grid_spec(src$location[[1]])$grid
  ds <- lazy_dataset(src, grid, assets = "M")
  # all three bands in one plan, through the scheduler's fetch split
  p <- plan_lazy(ds[["M_b1"]] + ds[["M_b2"]] * 2 + ds[["M_b3"]] * 3)
  direct <- execute_plan(p)

  local_pools(2, 1, gdal_config = TRUE)
  tlog <- tempfile(fileext = ".csv")
  old <- options(garry.fetch = "force", garry.task_log = tlog)
  on.exit(options(old), add = TRUE)
  got <- execute_plan_mirai(p)
  expect_equal(got, direct)
  # one fetch per item, shared by all three bands
  tl <- read.csv(tlog)
  expect_identical(length(unique(tl$key[grepl("^f\\d+_", tl$key)])), 2L)
})

# One day slice tiled by two 3-band items (left and right halves).
.mb_split_items <- function(dir) {
  mk <- function(nm, x0) {
    f <- file.path(dir, nm)
    ds <- gdalraster::create("GTiff", f, 10, 16, 3, "Float32", return_obj = TRUE)
    ds$setGeoTransform(c(x0, 10, 0, 160, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    for (b in 1:3) {
      ds$setNoDataValue(b, -9999)
      ds$write(b, 0, 0, 10, 16, rep(b, 160))
    }
    ds$close()
    f
  }
  feats <- lapply(1:2, function(i) {
    x0 <- (i - 1) * 100
    bb <- gdalraster::transform_bounds(c(x0, 0, x0 + 100, 160),
                                       "EPSG:3857", "EPSG:4326")
    list(id = sprintf("half-%d", i), bbox = as.list(bb),
         properties = list(datetime = "2023-01-05T01:00:00Z"),
         assets = list(M = list(href = mk(sprintf("H%d.tif", i), x0))))
  })
  list(features = feats)
}

test_that("a failed multi-band fetch holes only its own footprint", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  dir <- withr::local_tempdir("mb")
  src <- stac_sources(.mb_split_items(dir), assets = "M")
  grid <- grid_spec("EPSG:3857", extent = c(0, 0, 200, 160),
                    dims = c(20L, 16L), dtype = "f32")
  ds <- lazy_dataset(src, grid, assets = "M")

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.fetch = "force", garry.read_fail = "nodata",
                 garry.read_retry = 0L)
  on.exit(options(old), add = TRUE)
  # the right half vanishes after construction (expired token, deleted
  # blob). Its placeholder must carry three bands: with one, reading
  # band 2 of the slice fails ("has not enough bands") and the whole
  # slice, the surviving left half included, reads as a hole.
  unlink(src$location[[2L]])
  for (b in 2:3) {
    got <- suppressWarnings(collect(ds[[paste0("M_b", b)]]))
    expect_true(all(got[, 1:10] == b))
    expect_true(all(is.nan(got[, 11:20])))
  }
})
