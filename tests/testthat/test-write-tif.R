# write_tif (design #8): the file-writing sibling of collect().
# Streams through the same routes; dtype/scale/offset quantize at the
# sink boundary (round((v - offset)/scale) then NaN -> nodata, so the
# sentinel lives in DN units); cog = TRUE finalises via one translate.

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

# Pools spawned in a scratch directory: daemons resolve a relative path in the
# working directory they start in.
local({
  withr::local_dir(withr::local_tempdir())
  local_pools(2, 1)

  test_that("relative and dot-prefixed paths stream-write correctly under pools", {
    # Regression: the writer daemon caches open datasets keyed by PATH,
    # and ls() hides dot-prefixed names by default, so a "./out.tif" key
    # (which cog = TRUE manufactured for every relative target) escaped
    # .daemon_write_close: the file was returned as an unflushed
    # zero-filled shell while the data sat in the writer's block cache.
    # A plain write and a COG through stream, close and translate, each
    # against an R reference: a zero-filled temp fails on its values.
    s <- .wt_src()
    x <- lazy_source(s$f) + 0
    write_tif(x, "./rel-dot.tif", dtype = "i16", scale = 1e-4, offset = -0.1,
              nodata = -32768, distributed = TRUE)
    write_tif(x, "rel-cog.tif", dtype = "i16", scale = 1e-4, offset = -0.1,
              nodata = -32768, cog = TRUE, distributed = TRUE)
    d <- methods::new(gdalraster::GDALRaster, "rel-cog.tif")
    expect_identical(d$getMetadataItem(0, "LAYOUT", "IMAGE_STRUCTURE"), "COG")
    d$close()
    ref <- round((s$m - (-0.1)) / 1e-4)
    for (p in c("./rel-dot.tif", "rel-cog.tif")) {
      got <- matrix(collect(lazy_source(p), distributed = FALSE), 20)
      expect_identical(is.nan(got), is.nan(s$m))
      expect_equal(got[!is.nan(s$m)], ref[!is.nan(s$m)])
    }
  })

  test_that("distributed quantized write matches host, on the scheduler route", {
    s <- .wt_src()
    x <- lazy_source(s$f) + 0
    .local_px(100, x)
    ph <- tempfile(fileext = ".tif"); pd <- tempfile(fileext = ".tif")
    write_tif(x, ph, dtype = "i16", scale = 1e-4, offset = -0.1,
              nodata = -32768, distributed = FALSE)
    write_tif(x, pd, dtype = "i16", scale = 1e-4, offset = -0.1,
              nodata = -32768, distributed = TRUE)
    expect_identical(garry_last_route(), "scheduler")
    a1 <- collect(lazy_source(ph), distributed = FALSE)
    a2 <- collect(lazy_source(pd), distributed = FALSE)
    # one device quantizer for every route: digital numbers are EXACTLY
    # identical (file bytes may differ in tile order under streaming)
    expect_identical(unclass(unname(a1)), unclass(unname(a2)))
    md <- gdal_grid_spec(pd)
    expect_identical(md$grid@dtype, "i16")
    expect_identical(md$scale, 1e-4)
  })
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
  for (bad in list(NA, NaN, Inf, 0)) {
    expect_error(write_tif(x, tempfile(fileext = ".tif"), dtype = "i16",
                           scale = bad),
                 "finite, non-zero")
  }
  expect_error(write_tif(x, tempfile(fileext = ".tif"), dtype = "i16",
                         scale = 1e-4, offset = NA),
               "finite, non-zero")
})

# An i16 plan whose output is 100 + 1, quantized at scale 0.5: 202 on disk.
.wt_int_plan <- function() {
  f <- tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", f, 40L, 40L, 1L, "Int16", return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 400, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1L, 0L, 0L, 40L, 40L, rep(100, 1600L))
  ds$close()
  lazy_source(f) + 1L
}

test_that("an integer plan quantizes like a float one, in process", {
  p <- tempfile(fileext = ".tif")
  write_tif(.wt_int_plan(), p, dtype = "i16", scale = 0.5, distributed = FALSE)
  expect_true(all(collect(lazy_source(p)) == 202))
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

test_that("eager g_quantize runs jitted with the op-by-op values", {
  set.seed(3)
  # values on and around the rounding half-steps of scale 0.01
  x <- c(round(runif(4000, -40, 400), 2) + 0.005 * sample(-1:1, 4000, TRUE),
         runif(4000, -400, 4000), NaN, 1e9, -1e9, 0)
  dev <- g_upload(matrix(x, 4L), "f32")
  step_by_step <- function(scale, offset, nodata, lo, hi, dtype) {
    q <- g_clamp(g_round((dev - offset) / scale), lo, hi)
    g_download(g_cast(g_ifelse(g_is_nodata(dev), nodata, q), dtype))
  }
  expect_identical(
    g_download(g_quantize(dev, 0.01, 0, -32768, "i16")),
    step_by_step(0.01, 0, -32768, -32767, 32767, "i16")
  )
  expect_identical(
    g_download(g_quantize(dev, 0.25, -10, 255, "u8")),
    step_by_step(0.25, -10, 255, 0, 254, "u8")
  )
})

test_that("jitted quantizers are cached per exact quantization", {
  qj <- garry:::.g_quantize_jit
  # the same numbers split differently are different quantizations
  expect_false(identical(qj(c(1, 2), 3, -1, "i16"), qj(1, c(2, 3), -1, "i16")))
  expect_identical(qj(0.01, 0, -32768, "i16"), qj(0.01, 0, -32768, "i16"))
})

test_that("re-reading a rewritten file returns the new pixels", {
  f <- fixture_gradient_f32()
  path <- withr::local_tempfile(fileext = ".tif")
  x <- lazy_source(f)
  write_tif(x, path)
  first <- collect(lazy_source(path))
  write_tif(x * 2, path)
  second <- collect(lazy_source(path))
  expect_equal(second, 2 * first, ignore_attr = TRUE)
})

test_that("band_names reach the file and the collected result", {
  f <- fixture_gradient_f32()
  ds <- as_dataset(list(a = lazy_source(f), b = lazy_source(f) * 2))
  path <- withr::local_tempfile(fileext = ".tif")
  write_tif(ds, path, band_names = c("red", "nir"))
  r <- methods::new(gdalraster::GDALRaster, path)
  on.exit(r$close(), add = TRUE)
  expect_identical(c(r$getDescription(1L), r$getDescription(2L)), c("red", "nir"))
  # the default is the dataset's band names, and collect() carries them
  expect_identical(attr(collect(ds), "gis")$band_names, c("a", "b"))
})

test_that("write targets are checked before anything runs", {
  f <- fixture_gradient_f32()
  x <- list(a = lazy_source(f), b = lazy_source(f) * 2)
  d <- withr::local_tempdir()
  expect_error(write_tif(x, file.path(d, c("a.tif", "b.tif"))), "one path per sink")
  expect_error(write_tif(x, file.path(d, "one.tif")), "existing directory")
  expect_error(
    write_tif(x, c(a = file.path(d, "a.tif"), z = file.path(d, "z.tif"))),
    "named like"
  )
  expect_error(write_tif(lazy_source(f), file.path(d, c("a.tif", "b.tif"))), "single file path")
  out <- write_tif(x, c(a = file.path(d, "a.tif"), b = file.path(d, "b.tif")))
  expect_true(all(file.exists(file.path(d, c("a.tif", "b.tif")))))
})

test_that("a directory target returns the per-sink files", {
  f <- fixture_gradient_f32()
  x <- list(a = lazy_source(f), b = lazy_source(f) * 2)
  d <- withr::local_tempdir()
  out <- write_tif(x, d, distributed = FALSE)
  expect_identical(out, c(a = file.path(d, "a.tif"), b = file.path(d, "b.tif")))
  d2 <- withr::local_tempdir()
  out2 <- write_tif(x, d2, cog = TRUE, distributed = FALSE)
  expect_setequal(basename(unlist(out2)), c("a.tif", "b.tif"))
  expect_setequal(list.files(d2), c("a.tif", "b.tif"))
})

test_that("quantized values saturating at a nodata limit stay valid", {
  f <- fixture_gradient_f32()
  path <- withr::local_tempfile(fileext = ".tif")
  # everything far above u8's range, nodata at its top
  write_tif(lazy_source(f) * 1000, path, dtype = "u8", scale = 1, offset = 0, nodata = 255)
  v <- gdal_read_window(path, 1L, 0L, 0L, 60L, 40L)
  expect_true(all(v == 254))
})

test_that("write_tif validates dtype, nodata and quantization up front", {
  x <- lazy_source(fixture_gradient_f32())
  p <- withr::local_tempfile(fileext = ".tif")
  expect_error(write_tif(x, p, dtype = "f16"), "must be one of")
  expect_error(write_tif(x, p, nodata = c(1, 2)), "single number")
  expect_error(write_tif(x, p, nodata = "a"), "single number")
  expect_error(write_tif(x, p, dtype = "i16", nodata = 1.5), "whole number")
  expect_error(write_tif(x, p, dtype = "u32", scale = 0.1), "other than u32")
})

test_that("nodata must fit the dtype the plan writes", {
  f <- fixture_tile(1:16, type = "Byte")
  x <- lazy_source(f)
  expect_identical(x@grid@dtype, "u8")
  p <- tempfile(fileext = ".tif")
  bad <- function(...) {
    expect_error(write_tif(x, p, ..., distributed = FALSE),
                 class = "garry_write_error")
  }
  bad(nodata = -1)
  bad(nodata = 256)
  expect_error(write_tif(x, p, nodata = 1.5, distributed = FALSE), "whole number")
  bad(nodata = NaN)
  expect_error(write_tif(x, p, dtype = "f32", nodata = 1e39, distributed = FALSE),
               class = "garry_write_error")
  # each sink of a list, and a checkpoint's sentinel, are held to it too
  sinks <- list(a = x, b = lazy_source(f) * 1.5)
  paths <- c(a = tempfile(fileext = ".tif"), b = tempfile(fileext = ".tif"))
  expect_error(write_tif(sinks, paths, nodata = -1, distributed = FALSE),
               class = "garry_write_error")
  expect_error(materialise(x, tempfile("mat-"), nodata = -1, distributed = FALSE),
               class = "garry_write_error")
  expect_false(any(file.exists(c(p, paths))))
  # a hole in an integer plan keeps its sentinel, rather than reading as 0
  wide <- grid_spec("EPSG:3857", extent = c(0, 0, 80, 40), dims = c(8L, 4L))
  write_tif(align_to(x, wide), p, nodata = 255, distributed = FALSE)
  back <- collect(lazy_source(p), distributed = FALSE)
  expect_true(all(is.nan(back[, 5:8])) && !anyNA(back[, 1:4]))
  # an explicit dtype is what the sentinel must fit
  write_tif(x, p, dtype = "i16", nodata = -1, distributed = FALSE)
  expect_identical(gdal_grid_spec(p)$nodata, -1)
})

test_that("a write refused before its first byte leaves an existing file", {
  x <- lazy_source(fixture_tile(1:16, type = "Byte"))
  p <- tempfile(fileext = ".tif")
  writeLines("keep", p)
  expect_error(write_tif(x, p, nodata = -1, distributed = FALSE),
               class = "garry_write_error")
  expect_identical(readLines(p), "keep")
  # one that fails part way has already replaced it, and leaves nothing
  wide <- grid_spec("EPSG:3857", extent = c(0, 0, 80, 40), dims = c(8L, 4L))
  expect_error(write_tif(align_to(x, wide), p, distributed = FALSE), "sentinel")
  expect_false(file.exists(p))
})

test_that("a bad block size or a malformed creation option never reaches GDAL", {
  x <- lazy_source(fixture_gradient_f32())
  # GDAL reads BLOCKSIZE=abc as 0, and the COG driver then allocates without
  # bound. These stand in for GDAL, so a missed check fails here and goes no
  # further.
  local_mocked_bindings(
    gdal_create_output = function(...) stop("reached GDAL"),
    gdal_translate_file = function(...) stop("reached GDAL")
  )
  for (o in c("BLOCKSIZE=abc", "BLOCKSIZE=0", "BLOCKSIZE=-512", "BLOCKSIZE=512.5",
              "BLOCKSIZE=1e3", "BLOCKSIZE=", "BLOCKSIZE=99999999999",
              "blocksize=abc", "BLOCKSIZE:abc", "BLOCKXSIZE=abc", "BLOCKYSIZE=0")) {
    for (cog in c(TRUE, FALSE)) {
      expect_error(
        write_tif(x, tempfile(fileext = ".tif"), cog = cog,
                  creation_options = c("COMPRESS=DEFLATE", o), distributed = FALSE),
        "must be a positive whole number", class = "garry_write_error"
      )
    }
  }
  for (o in list(c(COMPRESS = "ZSTD"), "COMPRESS", NA_character_, 512)) {
    expect_error(
      write_tif(x, tempfile(fileext = ".tif"), creation_options = o, distributed = FALSE),
      "KEY=VALUE", class = "garry_write_error"
    )
  }
})

test_that("a valid block size reaches the COG driver", {
  x <- lazy_source(fixture_gradient_f32())
  p <- tempfile(fileext = ".tif")
  write_tif(x, p, cog = TRUE, creation_options = "BLOCKSIZE=32", distributed = FALSE)
  expect_identical(gdal_grid_spec(p)$block_dim, c(32L, 32L))
})

test_that("band_names must name every output band", {
  f <- withr::local_tempfile(fileext = ".tif")
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(4L, 4L, 2L) |>
    stats::setNames(c("x", "y", "band")))
  expect_error(gdal_create_output(f, g, band_names = "only_one"), "band_names")
})

test_that("a NaN sentinel on a float write declares nothing", {
  x <- lazy_source(fixture_gradient_f32()) * 2
  p <- tempfile(fileext = ".tif")
  write_tif(x, p, dtype = "f32", nodata = NaN, distributed = FALSE)
  expect_equal(unclass(collect(lazy_source(p), distributed = FALSE)), unclass(collect(x, distributed = FALSE)),
               ignore_attr = TRUE)
})

test_that("write_tif() refuses what it would ignore", {
  x <- lazy_source(fixture_gradient_f32())
  out <- tempfile(fileext = ".tif")
  expect_error(write_tif(x, out, cog = "yes"), "cog", fixed = TRUE)
  expect_error(write_tif(x, out, cog = 1), "cog", fixed = TRUE)
  expect_error(write_tif(x, out, overview_resampling = "nearest"), "cog = TRUE", fixed = TRUE)
})
