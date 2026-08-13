# write_tif (design #8): the file-writing sibling of collect().
# Streams through the same routes; dtype/scale/offset quantize at the
# sink boundary (round((v - offset)/scale) then NaN -> nodata, so the
# sentinel lives in DN units); cog = TRUE finalises via one translate.

skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

.wt_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 300, 200),
                      dims = c(x = 30L, y = 20L), dtype = "f32")

.wt_src <- function(seed = 2) {
  f <- tempfile(fileext = ".tif")
  ds <- gdal_create_output(f, .wt_grid)
  set.seed(seed)
  m <- matrix(runif(600, -0.1, 1), nrow = 20, byrow = TRUE)
  m[2, 2] <- NaN
  gdal_write_window(ds, 0L, 0L, m, "f32", nodata = numeric(0), band = 1L)
  ds$close()
  list(f = f, m = m)
}

test_that("write_tif streams a plain f32 GeoTIFF, byte-faithful", {
  s <- .wt_src()
  p <- tempfile(fileext = ".tif")
  expect_invisible(write_tif(lazy_source(s$f) + 0, p))
  got <- matrix(collect(lazy_source(p)), 20)
  expect_identical(is.nan(got), is.nan(s$m))
  expect_equal(got, s$m, tolerance = 1e-7)
})

test_that("quantized i16 write: metadata, sentinel, half-step accuracy", {
  s <- .wt_src()
  p <- tempfile(fileext = ".tif")
  write_tif(lazy_source(s$f) + 0, p,
            dtype = "i16", scale = 1e-4, offset = -0.1, nodata = -32768)
  meta <- gdal_grid_spec(p)
  expect_identical(meta$grid@dtype, "i16")
  expect_identical(meta$scale, 1e-4)
  expect_identical(meta$offset, -0.1)
  expect_identical(meta$nodata, -32768)
  # reads back through the read-side affine: the two features compose
  got <- matrix(collect(lazy_source(p, scale = TRUE)), 20)
  expect_identical(is.nan(got), is.nan(s$m))
  expect_lte(max(abs(got - s$m), na.rm = TRUE), 5e-5 + 1e-12)  # scale/2
  # and the raw DN file agrees with round-half-even quantization
  dn <- matrix(collect(lazy_source(p)), 20)
  ref <- round((s$m - (-0.1)) / 1e-4)
  expect_equal(dn[!is.nan(s$m)], ref[!is.nan(s$m)])
})

test_that("cog = TRUE produces COG layout and leaves no temps", {
  s <- .wt_src()
  p <- file.path(tempdir(), "wt-cog.tif")
  write_tif(lazy_source(s$f) + 0, p, cog = TRUE)
  d <- methods::new(gdalraster::GDALRaster, p)
  expect_identical(d$getMetadataItem(0, "LAYOUT", "IMAGE_STRUCTURE"), "COG")
  d$close()
  expect_equal(matrix(collect(lazy_source(p)), 20), s$m, tolerance = 1e-7)
  expect_length(list.files(dirname(p), pattern = "garry-cog-"), 0L)
  unlink(p)
})

test_that("cog = TRUE under pools writes the same values as a plain write", {
  # End-to-end guard for the streamed-writer + translate composition:
  # a broken interaction anywhere in stream/close/translate would leave
  # the pre-created (zero-filled) temp as the COG's content.
  local_pools(2, 1)
  s <- .wt_src()
  x <- lazy_source(s$f) + 0
  pp <- file.path(tempdir(), "wt-pools-plain.tif")
  pc <- file.path(tempdir(), "wt-pools-cog.tif")
  write_tif(x, pp, dtype = "i16", scale = 1e-4, offset = -0.1,
            nodata = -32768, distributed = TRUE)
  write_tif(x, pc, dtype = "i16", scale = 1e-4, offset = -0.1,
            nodata = -32768, cog = TRUE, distributed = TRUE)
  d <- methods::new(gdalraster::GDALRaster, pc)
  expect_identical(d$getMetadataItem(0, "LAYOUT", "IMAGE_STRUCTURE"), "COG")
  d$close()
  a <- collect(lazy_source(pp)); b <- collect(lazy_source(pc))
  expect_identical(unclass(unname(a)), unclass(unname(b)))
  expect_gt(stats::sd(b, na.rm = TRUE), 0)     # not a constant-fill file
  unlink(c(pp, pc))
})

test_that("multi-export list form writes one file per sink (dir and cog)", {
  s <- .wt_src()
  x <- lazy_source(s$f) + 0
  d <- file.path(tempdir(), "wt-multi"); dir.create(d, showWarnings = FALSE)
  write_tif(list(a = x, b = x * 2), d)
  expect_setequal(list.files(d, pattern = "\\.tif$"), c("a.tif", "b.tif"))
  expect_equal(matrix(collect(lazy_source(file.path(d, "b.tif"))), 20),
               s$m * 2, tolerance = 1e-6)
  unlink(d, recursive = TRUE)
  pv <- c(a = tempfile(fileext = ".tif"), b = tempfile(fileext = ".tif"))
  write_tif(list(a = x, b = x * 2), pv, cog = TRUE)
  db <- methods::new(gdalraster::GDALRaster, pv[["b"]])
  expect_identical(db$getMetadataItem(0, "LAYOUT", "IMAGE_STRUCTURE"), "COG")
  db$close()
})

test_that("validation: quantize needs int dtype; sentinel must fit; no .vrt", {
  s <- .wt_src()
  x <- lazy_source(s$f) + 0
  expect_error(write_tif(x, tempfile(fileext = ".tif"), scale = 1e-4),
               "integer")
  expect_error(write_tif(x, tempfile(fileext = ".tif"), dtype = "i16",
                         scale = 1e-4, nodata = 99999),
               "does not fit")
  expect_error(write_tif(x, tempfile(fileext = ".vrt")), "materialise")
})

test_that("collect() no longer takes file-writing arguments", {
  s <- .wt_src()
  x <- lazy_source(s$f) + 0
  expect_error(collect(x, path = tempfile(fileext = ".tif")),
               "unused argument")
  expect_no_warning(write_tif(x, tempfile(fileext = ".tif")))
  expect_no_warning(materialise(x, dir = tempdir(),
                                name = paste0("wt-", as.integer(stats::runif(1, 1, 1e7)))))
})

test_that("distributed quantized write matches host, on the scheduler route", {
  local_pools(2, 1)
  f <- tempfile(fileext = ".tif")
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 3000, 2000),
                 dims = c(x = 300L, y = 200L), dtype = "f32")
  ds <- gdal_create_output(f, g)
  set.seed(3)
  m <- matrix(runif(60000, -0.1, 1), nrow = 200, byrow = TRUE)
  m[10, 10] <- NaN
  gdal_write_window(ds, 0L, 0L, m, "f32", nodata = numeric(0), band = 1L)
  ds$close()
  x <- lazy_source(f) + 0
  ph <- tempfile(fileext = ".tif"); pd <- tempfile(fileext = ".tif")
  write_tif(x, ph, dtype = "i16", scale = 1e-4, offset = -0.1,
            nodata = -32768, distributed = FALSE)
  write_tif(x, pd, dtype = "i16", scale = 1e-4, offset = -0.1,
            nodata = -32768, distributed = TRUE)
  expect_identical(garry_last_route(), "scheduler")
  a1 <- collect(lazy_source(ph)); a2 <- collect(lazy_source(pd))
  # one device quantizer for every route: digital numbers are EXACTLY
  # identical (file bytes may differ in tile order under streaming)
  expect_identical(unclass(unname(a1)), unclass(unname(a2)))
  md <- gdal_grid_spec(pd)
  expect_identical(md$grid@dtype, "i16")
  expect_identical(md$scale, 1e-4)
})

test_that("g_quantize matches the historical writer semantics", {
  x <- c(-0.05, 0.00005, 0.15005, 3.27675, 9, NaN)
  dev <- g_upload(matrix(x, 1L), "f32")
  q <- g_download(g_quantize(dev, 1e-4, 0, -32768, "i16"))
  ref <- round((x) / 1e-4)              # R round: half to even, like nv_round
  ref <- pmin(pmax(ref, -32768), 32767) # clamp = GDAL cast behaviour
  ref[is.na(ref)] <- -32768
  expect_equal(as.numeric(q), ref)
  # no sentinel + NaN present: the historical error, now from the device
  expect_error(
    g_download(g_quantize(dev, 1e-4, 0, numeric(0), "i16")),
    "no nodata sentinel")
  # no sentinel + NaN-free: legal (the historical contract)
  clean <- g_upload(matrix(c(0.1, 0.2), 1L), "f32")
  expect_equal(as.numeric(g_download(g_quantize(clean, 0.1, 0,
                                                numeric(0), "i16"))),
               c(1, 2))
})

test_that("a composite-shaped quantized write routes to the scheduler, identically", {
  # Quantized writes bypass the cd/gd fast paths by design (one device
  # quantizer for every route; folding g_quantize into the cd band
  # kernels is ir-extensions-todo #12). The same plan WITHOUT a wspec
  # still takes composite_direct (guarded below).
  local_pools(2, 2)
  x <- .gg_masked_composite()
  ph <- tempfile(fileext = ".tif"); pd <- tempfile(fileext = ".tif")
  write_tif(x, ph, dtype = "i16", scale = 0.5, offset = 0,
            nodata = -32768, distributed = FALSE)
  write_tif(x, pd, dtype = "i16", scale = 0.5, offset = 0,
            nodata = -32768, distributed = TRUE)
  expect_identical(garry_last_route(), "scheduler")
  a1 <- collect(lazy_source(ph)); a2 <- collect(lazy_source(pd))
  expect_identical(unclass(unname(a1)), unclass(unname(a2)))
  pf <- tempfile(fileext = ".tif")
  write_tif(x, pf, distributed = TRUE)
  expect_identical(garry_last_route(), "composite_direct")
  a1 <- collect(lazy_source(ph)); a2 <- collect(lazy_source(pd))
  expect_equal(unclass(a1), unclass(a2), ignore_attr = TRUE)
  md <- gdal_grid_spec(pd)
  expect_identical(md$grid@dtype, "i16")
  expect_identical(md$scale, 0.5)
})
