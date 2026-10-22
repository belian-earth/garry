# N-D arrays (Zarr) through lazy_dataset(): GDAL's classic view flattens a
# (time, band, y, x) array into one band per (time, band) pair and tags
# each with its dimension indices; garry lays those out as dataset bands x
# time slices. Gates: the layout and labels, band and time selection,
# values identical to the array (fill value -> NaN), each year's bands
# collapsing into one read on a target grid, and the signed-power decode.

.nd_ref <- function(fx, t, b) {
  v <- fx$vals[t, b, , ] * 1.0
  v[v == -128] <- NaN
  v
}

test_that(".gdal_band_dims reads an N-D array's time and band dimensions", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  bd <- .gdal_band_dims(.gdal_handle(fx$path))
  expect_identical(attr(bd, "dims"), c("time", "band"))
  expect_identical(nrow(bd), 12L)
  # time-major flattening: file band k is (time (k-1) %/% 4, band (k-1) %% 4)
  expect_identical(bd$time_index, rep(0:2, each = 4L))
  expect_identical(bd$band_index, rep(0:3, times = 3L))
  expect_identical(unique(bd$time_value), c("2021", "2022", "2023"))
  expect_null(.gdal_band_dims(.gdal_handle(fixture_multiband()$path)))
})

test_that("lazy_dataset() lays an N-D Zarr array out as bands x time slices", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  ds <- lazy_dataset(fx$path)
  expect_named(ds@bands, paste0("b", 1:4))
  expect_identical(time_labels(ds), c("2021", "2022", "2023"))
  for (t in 1:3) {
    got <- collect(time_sel(ds, t), distributed = FALSE)
    expect_identical(dim(got), c(20L, 30L, 4L))
    for (b in 1:4) {
      expect_equal(unname(got[, , b]), .nd_ref(fx, t, b))
    }
  }
})

test_that("bands and assets select along the band dimension", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  ds <- lazy_dataset(fx$path, bands = c(4L, 2L))
  expect_named(ds@bands, c("b4", "b2"))
  got <- collect(time_sel(ds, "2023"), distributed = FALSE)
  expect_equal(unname(got[, , 1]), .nd_ref(fx, 3, 4))
  expect_named(lazy_dataset(fx$path, assets = "b3")@bands, "b3")
  expect_error(lazy_dataset(fx$path, bands = 5L), "band dimension has 4")
})

test_that("time_sel() on a dataset keeps the matching slices of every band", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  ds <- lazy_dataset(fx$path)
  two <- time_sel(ds, c("2021", "2023"))
  expect_identical(lapply(two@bands, names)[[3]], c("2021", "2023"))
  expect_identical(time_labels(time_sel(ds, 2L)), "2022")
  expect_identical(time_labels(time_sel(ds, "202")), c("2021", "2022", "2023"))
  expect_error(time_sel(ds, "1999"), "match")
  # a reduction over the selected years works as on any dataset
  m <- collect(reduce_over(two, "mean", "t"), distributed = FALSE)
  expect_equal(unname(m[, , 2]), (.nd_ref(fx, 1, 2) + .nd_ref(fx, 3, 2)) / 2,
               tolerance = 1e-6)
})

test_that("a year's bands on a target grid collapse into one multi-band read", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  g <- grid_spec("EPSG:32632", c(500050, 4599850, 500250, 4599950), res = 10)
  yr <- time_sel(lazy_dataset(fx$path, g), "2023")
  p <- plan_lazy(stack_bands(yr))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  w <- graph_get(p@graph, p@stages[[which(kinds == "warp")]]@members[[1L]])
  expect_identical(w@bands, 9:12)
  got <- collect(yr, distributed = FALSE)
  for (b in 1:4) {
    expect_equal(unname(got[, , b]), .nd_ref(fx, 3, b)[6:15, 6:25])
  }
})

test_that("the OlmoEarth decode fuses onto a Zarr read, nodata staying NaN", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  ds <- lazy_map(time_sel(lazy_dataset(fx$path), "2022"),
                 fn = dequantize_olmoearth, dtype = "f32")
  got <- collect(ds, distributed = FALSE)
  ref <- .nd_ref(fx, 2, 3)
  expect_equal(unname(got[, , 3]), sign(ref) * (abs(ref) / 127.5)^2,
               tolerance = 1e-6)
  expect_true(is.nan(got[1, 1, 3]))
})

test_that("pooled reads of a Zarr dataset match the single-process read", {
  skip_on_cran()
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  local_pools(2, 1, gdal_config = TRUE)
  g <- grid_spec("EPSG:32632", c(500050, 4599850, 500250, 4599950), res = 10)
  yr <- lazy_map(time_sel(lazy_dataset(fx$path, g), "2021"),
                 fn = dequantize_olmoearth, dtype = "f32")
  expect_equal(collect(yr, distributed = TRUE),
               collect(yr, distributed = FALSE), tolerance = 0)
})

test_that("Zarr connection strings count as remote and get the vsicurl prefix", {
  expect_identical(.gdal_href('ZARR:"https://h/s.zarr/utm30":/embeddings'),
                   'ZARR:"/vsicurl/https://h/s.zarr/utm30":/embeddings')
  expect_identical(.gdal_href('ZARR:"/vsicurl/https://h/s.zarr":/e'),
                   'ZARR:"/vsicurl/https://h/s.zarr":/e')
  expect_true(.gdal_is_remote('ZARR:"/vsicurl/https://h/s.zarr":/e'))
  expect_true(.gdal_is_remote('ZARR:"/vsis3/b/s.zarr":/e'))
  expect_false(.gdal_is_remote('ZARR:"/data/s.zarr":/e'))
  expect_true(.gdal_is_zarr('ZARR:"/data/s.zarr":/e'))
  expect_false(.gdal_is_zarr("/data/a.tif"))
})

test_that("a Zarr handle is closed once its reads pass garry.zarr_handle_mb", {
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd()
  withr::local_options(garry.zarr_handle_mb = 600 / 2^20) # 600 bytes
  .gdal_handle_drop(fx$path)
  key <- .gdal_href(fx$path)
  a <- gdal_read_window(fx$path, 1L, 0L, 0L, 20L, 20L) # 400 bytes: kept
  h1 <- .gdal_cache$handles[[key]]
  expect_false(is.null(h1))
  b <- gdal_read_window(fx$path, 2L, 0L, 0L, 20L, 20L) # 800: reopened
  expect_false(identical(h1, .gdal_cache$handles[[key]]))
  expect_identical(.gdal_cache$zarr_bytes[[key]], 400)
  expect_equal(a, .nd_ref(fx, 1, 1)[1:20, 1:20])
  expect_equal(b, .nd_ref(fx, 1, 2)[1:20, 1:20])
})
