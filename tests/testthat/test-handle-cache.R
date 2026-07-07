# The dataset handle cache is LRU-capped: open mosaics pin warper and
# cache memory per process, so daemons reading many distinct slices
# must not accumulate handles (benchmark OOM regression guard).

test_that("handle cache stays within cap and evicted handles reopen", {
  .gdal_handle_reset()
  cap <- garry_opt("handle_cache_max")

  paths <- vapply(seq_len(cap + 3L), function(i) {
    fp <- file.path(tempdir(), sprintf("garry-hc-%d.tif", i))
    ds <- gdalraster::create("GTiff", fp, 4, 3, 1, "Float32",
                             return_obj = TRUE)
    ds$setGeoTransform(c(0, 1, 0, 3, 0, -1))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 4, 3, as.numeric(seq_len(12) * i))
    ds$close()
    fp
  }, character(1))

  for (p in paths) gdal_read_window(p, 1L, 0L, 0L, 4L, 3L)
  expect_lte(length(.gdal_cache$handles), cap)

  # The first path was evicted (and its handle closed); reading it
  # again must transparently reopen.
  m <- gdal_read_window(paths[[1L]], 1L, 0L, 0L, 4L, 3L)
  expect_equal(m[1, 1], 1)

  # Repeated reads of one path reuse a single cache slot.
  n0 <- length(.gdal_cache$handles)
  for (i in 1:5) gdal_read_window(paths[[cap + 3L]], 1L, 0L, 0L, 4L, 3L)
  expect_identical(length(.gdal_cache$handles), n0)
  .gdal_handle_reset()
})
