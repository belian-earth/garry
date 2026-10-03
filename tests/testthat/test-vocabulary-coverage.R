# Direct contracts for exported functions no other test names: the g_*
# shape and bitwise ops (traced against their pure-R oracles), every
# documented reduce_over() op through collect(), the GTI index builder
# and the GDAL config helper.

.traced1 <- function(f, ...) {
  args <- list(...)
  jf <- garry:::g_jit(function(inputs) list(out = do.call(f, inputs)))
  g_download(jf(lapply(args, g_upload, dtype = "f32")))$out
}

test_that("g_* shape and bitwise ops match their oracles when traced", {
  set.seed(3)
  cube <- array(runif(4 * 3 * 5), c(4, 3, 5))
  plane <- matrix(runif(15), 3, 5)
  eq <- function(f, ...) {
    expect_equal(.traced1(f, ...), f(...), tolerance = 1e-6, ignore_attr = TRUE)
  }
  eq(function(x) g_slice_t(x, 2L, 3L), cube)
  eq(function(x, p) g_concat_t(list(x, p)), cube, plane)
  eq(function(x) g_expand(x, 2L, 4L), plane)
  eq(function(x) g_squeeze1(g_slice_t(x, 2L, 2L)), cube)
  eq(function(x, w) {
    b <- g_broadcast_arrays(x, w)
    b[[1L]] * b[[2L]]
  }, cube, array(1:4, c(4, 1, 1)))
  eq(function(x) g_round(x * 10), plane)
  eq(function(x) g_clamp(x, 0.2, 0.8), plane)
  ints <- matrix(c(0, 1, 5, 12), 2, 2)
  expect_equal(
    .traced1(function(x) g_cast(g_bitnot(g_cast(x, "i32")), "f32"), ints),
    g_bitnot(ints) + 0,
    ignore_attr = TRUE
  )
})

test_that("every documented reduce_over op runs through collect", {
  a <- lazy_source(fixture_gradient_f32())
  st <- lazy_stack(list(a, a * 2, a * 4))
  v <- array(c(collect(a), collect(a * 2), collect(a * 4)), c(dim(a), 3L))
  base_op <- list(
    sum = sum, mean = mean, min = min, max = max, median = stats::median,
    count = function(z) sum(!is.na(z))
  )
  for (op in garry:::.reduce_ops) {
    got <- collect(reduce_over(st, op, "t"))
    want <- apply(v, c(1, 2), base_op[[op]])
    expect_equal(got, want, tolerance = 1e-5, ignore_attr = TRUE, info = op)
  }
})

test_that("stac_gti_index writes one footprint per item of an asset", {
  src <- data.frame(
    item_id = c("a", "b"),
    asset = "B1",
    location = c("x.tif", "y.tif"),
    datetime = c("2023-01-01T00:00:00Z", "2023-01-02T00:00:00Z"),
    cloud_cover = NA_real_,
    xmin = c(0, 1), ymin = 0, xmax = c(1, 2), ymax = 1
  )
  src <- stac_time_slices(src, "day")
  idx <- stac_gti_index(src, "B1", path = withr::local_tempfile(fileext = ".gti.fgb"))
  expect_true(file.exists(idx))
  expect_true(file.exists(paste0(idx, ".meta.rds")))
  meta <- readRDS(paste0(idx, ".meta.rds"))
  expect_identical(nrow(meta$entries), 2L)
})

test_that("garry_gdal_config sets the network options it documents", {
  old <- gdalraster::get_config_option("GDAL_HTTP_MAX_RETRY")
  on.exit(gdalraster::set_config_option("GDAL_HTTP_MAX_RETRY", old), add = TRUE)
  garry_gdal_config()
  expect_identical(gdalraster::get_config_option("GDAL_HTTP_MAX_RETRY"), "10")
})
