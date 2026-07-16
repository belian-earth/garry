# LazyDataset: the named multi-band, multi-time object whose verbs apply across
# every band. These gates fix that dataset ops equal the hand-written per-band /
# per-slice primitive path (as_dataset + reduce_over + mask vs manual lazy_stack
# + lazy_map), that masking (value-set, qa_bits, morphology) matches a manual
# mask, that indexing/collect assemble the band axis, and that the distributed
# executor reproduces the single-threaded oracle for a full masked composite.

# Two-slice, two-band dataset plus a QA band, all on one shared graph.
ds_fixture <- function(f) {
  g <- graph_new()
  src <- function() lazy_source(f, graph = g)
  as_dataset(
    list(
      V1 = list(s1 = src() * 1, s2 = src() * 2),
      V2 = list(s1 = src() * 3, s2 = src() * 4),
      Q  = list(s1 = src(),     s2 = src() + 1)
    ),
    mask_asset = "Q"
  )
}

test_that("as_dataset builds a named dataset; indexing round-trips", {
  ds <- ds_fixture(fixture_gradient_f32())
  expect_true(S7::S7_inherits(ds, LazyDataset))
  expect_identical(names(ds@bands), c("V1", "V2", "Q"))
  expect_identical(ds@mask_asset, "Q")
  # [[ ]] on a multi-slice band -> a (t, y, x) LazyRaster; [ ] -> sub-dataset
  expect_true(S7::S7_inherits(ds[["V1"]], LazyRaster))
  sub <- ds[c("V1", "V2")]
  expect_true(S7::S7_inherits(sub, LazyDataset))
  expect_identical(names(sub@bands), c("V1", "V2"))
  expect_length(sub@mask_asset, 0L)   # Q not in the subset
})

test_that("reduce_over per band equals the manual stack+reduce path", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)

  red <- reduce_over(ds, "median", "t")
  expect_true(all(vapply(red@bands, length, 1L) == 1L))  # one composite per band
  out <- collect(red)                                    # (y, x, band)
  expect_equal(dim(out), c(40L, 60L, 3L))

  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  manual_V1 <- collect(reduce_over(lazy_stack(list(s() * 1, s() * 2)), "median", "t"))
  expect_equal(out[, , 1], manual_V1, tolerance = 1e-6, ignore_attr = "gis")
})

test_that("collect on a single-band dataset returns a matrix", {
  skip_if_not_installed("anvl")
  ds <- ds_fixture(fixture_gradient_f32())["V1"]
  out <- collect(reduce_over(ds, "mean", "t"))
  expect_equal(dim(out), c(40L, 60L))
})

test_that("mask(qa_bits) equals a manual bitmask + apply", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)

  masked <- mask(ds, where = qa_bits(0:1))
  expect_false("Q" %in% names(masked@bands))            # QA dropped
  got <- collect(reduce_over(masked, "median", "t"))

  # manual: bad = (value & 3) > 0 with nodata->clear; NaN out the bad pixels
  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  bad <- function(fv) {
    fc <- g_ifelse(g_is_nodata(fv), 0, fv)
    g_cast(g_bitand(g_cast(fc, "i32"), 3L) > 0, "f32")
  }
  ap <- function(v, b) lazy_map(v, b, fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, vv),
                                dtype = "f32")
  V1s1 <- s() * 1; V1s2 <- s() * 2; Q1 <- s(); Q2 <- s() + 1
  m1 <- ap(V1s1, lazy_map(Q1, fn = bad, dtype = "f32"))
  m2 <- ap(V1s2, lazy_map(Q2, fn = bad, dtype = "f32"))
  manual <- collect(reduce_over(lazy_stack(list(m1, m2)), "median", "t"))
  expect_equal(got[, , 1], manual, tolerance = 1e-6, ignore_attr = "gis")
})

test_that("mask(value set) flags category membership", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)

  # values are r*100+c; mask the exact set of QA values present in slice s1 of Q
  # (Q s1 == the raw fixture). Pick a handful of concrete values.
  vals <- c(101, 202, 303)
  got <- collect(reduce_over(mask(ds, where = vals), "median", "t"))

  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  memb <- function(fv) {
    ind <- lapply(vals, function(v) g_cast(fv == v, "f32"))
    g_cast(Reduce(`+`, ind) > 0, "f32")
  }
  ap <- function(v, b) lazy_map(v, b, fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, vv),
                                dtype = "f32")
  V1s1 <- s() * 1; V1s2 <- s() * 2; Q1 <- s(); Q2 <- s() + 1
  m1 <- ap(V1s1, lazy_map(Q1, fn = memb, dtype = "f32"))
  m2 <- ap(V1s2, lazy_map(Q2, fn = memb, dtype = "f32"))
  manual <- collect(reduce_over(lazy_stack(list(m1, m2)), "median", "t"))
  expect_equal(got[, , 1], manual, tolerance = 1e-6, ignore_attr = "gis")
})

test_that("mask morphology (open + dilate) matches a manual erode/dilate chain", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)
  got <- collect(reduce_over(mask(ds, where = qa_bits(0:1), open = 2, dilate = 3),
                             "median", "t"))

  disk <- function(r) { o <- expand.grid(dx = -r:r, dy = -r:r); which(o$dx^2 + o$dy^2 <= r^2) }
  ero  <- function(x, r) { sel <- disk(r); focal(x, radius = as.integer(r),
                                                 fn = function(sh) Reduce(`*`, sh[sel])) }
  dil  <- function(x, r) { sel <- disk(r); focal(x, radius = as.integer(r),
                                                 fn = function(sh) 1 - Reduce(`*`, lapply(sh[sel], function(s) 1 - s))) }
  g <- graph_new()
  s <- function() lazy_source(f, graph = g)
  bad <- function(fv) { fc <- g_ifelse(g_is_nodata(fv), 0, fv); g_cast(g_bitand(g_cast(fc, "i32"), 3L) > 0, "f32") }
  clean <- function(q) dil(dil(ero(lazy_map(q, fn = bad, dtype = "f32"), 2), 2), 3)
  ap <- function(v, b) lazy_map(v, b, fn = function(vv, mm) g_ifelse(mm > 0.5, NaN, vv), dtype = "f32")
  V1s1 <- s() * 1; V1s2 <- s() * 2; Q1 <- s(); Q2 <- s() + 1
  m1 <- ap(V1s1, clean(Q1)); m2 <- ap(V1s2, clean(Q2))
  manual <- collect(reduce_over(lazy_stack(list(m1, m2)), "median", "t"))
  expect_equal(got[, , 1], manual, tolerance = 1e-6, ignore_attr = "gis")
})

test_that("lazy_map over a dataset skips the mask band; bands= selects", {
  ds <- ds_fixture(fixture_gradient_f32())
  scaled <- lazy_map(ds, fn = function(v) v / 10, dtype = "f32")
  expect_identical(scaled@bands$Q, ds@bands$Q)           # QA untouched
  expect_false(identical(scaled@bands$V1, ds@bands$V1))  # value band changed

  one <- lazy_map(ds, fn = function(v) v / 10, dtype = "f32", bands = "V1")
  expect_false(identical(one@bands$V1, ds@bands$V1))
  expect_identical(one@bands$V2, ds@bands$V2)             # V2 not selected
})

test_that("stack_bands needs one layer per band", {
  ds <- ds_fixture(fixture_gradient_f32())
  expect_error(stack_bands(ds), "one layer per band")
  expect_silent(stack_bands(reduce_over(ds["V1"], "mean", "t")))
})

test_that("scalar arithmetic scales value bands and leaves the mask band", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ds <- ds_fixture(f)
  scaled <- ds * 0.1
  expect_identical(scaled@bands$Q, ds@bands$Q)           # QA untouched
  got <- collect(reduce_over(scaled["V1"], "mean", "t"))

  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  manual <- collect(reduce_over(lazy_stack(list((s() * 1) * 0.1, (s() * 2) * 0.1)),
                                "mean", "t"))
  expect_equal(got, manual, tolerance = 1e-6)
  expect_true(S7::S7_inherits(100 - ds, LazyDataset))    # scalar-first
})

test_that("dataset + dataset combines shared value bands slice by slice", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  a <- ds_fixture(f)                                      # V1, V2, Q
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  b <- as_dataset(list(V1 = list(s() * 10, s() * 20)))   # only V1 in common

  summed <- a + b
  expect_identical(names(summed@bands), "V1")            # intersection of value bands
  expect_length(summed@mask_asset, 0L)
  got <- collect(reduce_over(summed, "mean", "t"))

  manual <- collect(reduce_over(
    lazy_stack(list(s() * 1 + s() * 10, s() * 2 + s() * 20)), "mean", "t"))
  expect_equal(as.numeric(got), as.numeric(manual), tolerance = 1e-6)
})

# Fabricate a doc_items-shaped list with a value asset (V) and a QA asset (Q)
# over local tiles, so lazy_dataset()'s STAC path (per-asset GTI index + grid
# probe + slice mosaics) runs fully offline. Q holds small integer flags that
# vary per slice so masking differs across time.
.ds_fake_items <- function() {
  dates <- c("2023-01-05T01:00:00Z", "2023-01-15T01:00:00Z", "2023-02-05T01:00:00Z")
  mk <- function(nm, m) {
    f <- file.path(tempdir(), nm)
    ds <- gdalraster::create("GTiff", f, 20, 16, 1, "Float32", return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 160, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 20, 16, as.numeric(t(m)))
    ds$close()
    f
  }
  b <- gdalraster::transform_bounds(c(0, 0, 200, 160), "EPSG:3857", "EPSG:4326")
  feats <- lapply(1:3, function(i) {
    V <- outer(1:16, 1:20, function(r, c2) r * 100 + c2) + (i - 1) * 1000
    Q <- matrix((seq_len(16 * 20) + i) %% 5, 16, 20)   # flags 0..4, vary by slice
    list(id = sprintf("item-%d", i), bbox = as.list(b),
         properties = list(datetime = dates[[i]], `eo:cloud_cover` = 10),
         assets = list(V = list(href = mk(sprintf("garry-ds-V%d.tif", i), V)),
                       Q = list(href = mk(sprintf("garry-ds-Q%d.tif", i), Q))))
  })
  list(features = feats)
}

test_that("lazy_dataset builds from a STAC table and masks end to end (offline)", {
  skip_if_not_installed("anvl")
  src  <- stac_sources(.ds_fake_items(), assets = c("V", "Q"))
  vloc <- src$location[src$asset == "V"]
  qloc <- src$location[src$asset == "Q"]
  grid <- gdal_grid_spec(vloc[[1]])$grid                 # native 3857 grid

  ds <- lazy_dataset(src, grid, assets = "V", mask_asset = "Q")
  expect_identical(names(ds@bands), c("V", "Q"))
  expect_identical(ds@mask_asset, "Q")
  expect_length(ds@bands$V, 3L)                          # three day slices
  expect_named(ds@bands$V, c("2023-01-05", "2023-01-15", "2023-02-05"))

  got <- collect(reduce_over(mask(ds, where = qa_bits(0:1)), "median", "t"))

  # plain-R reference: bad = (int(Q) & 3) > 0 -> NaN, then median over slices
  rd <- function(f) gdal_read_window(f, 1L, 0L, 0L, 20L, 16L)
  slabs <- lapply(1:3, function(i) {
    v <- rd(vloc[[i]]); q <- rd(qloc[[i]])
    v[bitwAnd(as.integer(q), 3L) > 0] <- NaN
    v
  })
  arr  <- g_stack(slabs)
  want <- apply(arr, c(2, 3), function(v) { m <- median(v, na.rm = TRUE); if (is.na(m)) NaN else m })
  expect_identical(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("lazy_dataset threads resampling to value bands, keeps the mask near", {
  src  <- stac_sources(.ds_fake_items(), assets = c("V", "Q"))
  grid <- gdal_grid_spec(src$location[src$asset == "V"][[1]])$grid
  rs_of <- function(ds, b) unique(vapply(ds@bands[[b]], function(lr)
    graph_get(lr@graph, lr@node_id)@resampling, ""))

  ds <- lazy_dataset(src, grid, assets = "V", mask_asset = "Q",
                     resampling = "average")
  expect_identical(rs_of(ds, "V"), "average")   # value band interpolates
  expect_identical(rs_of(ds, "Q"), "near")      # QA mask forced nearest

  # named per-asset form; a default of near for anything unnamed
  ds2 <- lazy_dataset(src, grid, assets = "V", mask_asset = "Q",
                      resampling = c(V = "bilinear"))
  expect_identical(rs_of(ds2, "V"), "bilinear")
  expect_identical(rs_of(ds2, "Q"), "near")

  # default is near, and an unknown method is rejected
  expect_identical(rs_of(lazy_dataset(src, grid, assets = "V"), "V"), "near")
  expect_error(lazy_dataset(src, grid, assets = "V", resampling = "bogus"),
               "Invalid")
})

test_that("resampling actually rescales the warp-on-read (near vs average)", {
  skip_if_not_installed("anvl")
  dir <- withr::local_tempdir("dsrs")
  s <- file.path(dir, "g.tif")
  d <- gdalraster::create("GTiff", s, 16, 16, 1, "Float32", return_obj = TRUE)
  d$setGeoTransform(c(0, 10, 0, 160, 0, -10))
  d$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  V <- outer(1:16, 1:16, function(r, c2) r * 100 + c2)     # smooth gradient
  d$write(1, 0, 0, 16, 16, as.numeric(t(V))); d$close()
  idx <- file.path(dir, "i.gti.fgb")
  gti_index_create(data.frame(location = s, datetime = "2023-01-01T00:00:00Z",
                              slice = "2023-01-01", cloud_cover = 0,
                              xmin = 0, ymin = 0, xmax = 160, ymax = 160),
                   idx, crs = "EPSG:3857")
  coarse <- grid_spec("EPSG:3857", extent = c(0, 0, 160, 160),
                      dims = c(8L, 8L), dtype = "f32")       # 2x coarser
  meta <- gdal_grid_spec(paste0("GTI:", idx),
                         open_options = gti_open_options(coarse))
  rd <- function(rs) collect(lazy_source(
    paste0("GTI:", idx), grid = meta$grid,
    open_options = gti_open_options(coarse, filter = "slice = '2023-01-01'",
                                    sort_field = "datetime"),
    resampling = rs), distributed = FALSE)

  near <- rd("near"); avg <- rd("average")
  expect_false(isTRUE(all.equal(unname(near), unname(avg))))  # resampling applied
  # the top-left coarse cell covers source pixels {101,102,201,202}: mean 151.5
  expect_equal(unname(avg[1, 1]), 151.5, tolerance = 1e-4)
  expect_true(unname(near[1, 1]) %in% c(101, 102, 201, 202))  # near picks a sample
})

test_that("a derived band joins the graph and is written by collect", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  comp <- as_dataset(list(B04 = list(s() * 1), B03 = list(s() * 2),
                          B02 = list(s() * 3)))

  comp[["ratio"]] <- comp[["B03"]] * comp[["B02"]]
  expect_identical(names(comp@bands), c("B04", "B03", "B02", "ratio"))

  out <- collect(comp)                          # (y, x, band)
  expect_equal(dim(out), c(40L, 60L, 4L))       # the derived band is written
  b03 <- collect(comp[["B03"]]); b02 <- collect(comp[["B02"]])
  expect_equal(out[, , 4], b03 * b02, tolerance = 1e-4, ignore_attr = "gis")

  # an index-style band from arithmetic + scalars also composes
  comp[["ndvi"]] <- (comp[["B04"]] - comp[["B03"]]) /
    (comp[["B04"]] + comp[["B03"]])
  expect_equal(dim(collect(comp)), c(40L, 60L, 5L))
})

test_that("assigning a band on the wrong grid is rejected", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  comp <- as_dataset(list(B04 = list(lazy_source(f, graph = g))))
  other <- lazy_source(fixture_i16_nodata())    # different grid
  expect_error({ comp[["bad"]] <- other }, "grid")
  expect_error({ comp[["x"]] <- 42 }, "LazyRaster")
})

test_that("collect writes dataset band names as GDAL descriptions", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(red = list(s()), green = list(s() * 2), blue = list(s() * 3)))
  ds[["ndvi"]] <- ds[["red"]] / ds[["green"]]
  out <- tempfile(fileext = ".tif")
  collect(ds, path = out, nodata = -9999, distributed = FALSE)
  r <- new(gdalraster::GDALRaster, out); on.exit(r$close())
  expect_equal(vapply(1:4, function(b) r$getDescription(b), character(1)),
               c("red", "green", "blue", "ndvi"))
})

test_that("distributed collect writes band descriptions too", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  garry_daemons(2, 2, gdal_config = FALSE)
  on.exit(garry_daemons(0, 0, gdal_config = FALSE), add = TRUE)

  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(a = list(s(), s() * 2), b = list(s() * 3, s() * 4)))
  comp <- reduce_over(ds, "median", "t")     # plain sources -> scheduler path
  out <- tempfile(fileext = ".tif")
  collect(comp, path = out, distributed = TRUE)
  r <- new(gdalraster::GDALRaster, out); on.exit(r$close(), add = TRUE)
  expect_equal(vapply(1:2, function(b) r$getDescription(b), character(1)),
               c("a", "b"))
})

test_that("distributed masked composite equals the oracle", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)   # force multiple spatial chunks
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  build <- function() reduce_over(mask(ds_fixture(f), where = qa_bits(0:1), dilate = 2),
                                  "median", "t")
  expect_equal(collect(build(), distributed = TRUE),
               collect(build(), distributed = FALSE),
               tolerance = 1e-6)
})
