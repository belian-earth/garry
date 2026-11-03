# Read-side scale/offset (design #6): discovery from TIFF band metadata
# only, applied inside the read kernel AFTER sentinel -> NaN, so the
# graph shape is identical to an unscaled read and every route (host,
# scheduler, composite_direct) sees physical values.

.sr_grid <- grid_spec("EPSG:3857", extent = c(0, 0, 300, 200),
                      dims = c(x = 30L, y = 20L), dtype = "i16")

# An Int16 tile with a sentinel and (optionally) scale/offset metadata.
.sr_tile <- function(m, nodata = -9999, scale = NULL, offset = NULL) {
  f <- tempfile(fileext = ".tif")
  ds <- gdal_create_output(f, .sr_grid, nodata = nodata)
  gdal_write_window(ds, 0L, 0L, m, "i16", nodata = numeric(0), band = 1L)
  if (!is.null(scale)) {
    ds$setScale(1, scale)
    ds$setOffset(1, offset)
  }
  ds$close()
  f
}

.sr_m <- function(seed = 1) {
  set.seed(seed)
  m <- matrix(as.numeric(sample(0:9999, 600, TRUE)), nrow = 20, byrow = TRUE)
  m[3, 4] <- -9999
  m
}

test_that("gdal_grid_spec discovers band scale/offset from the file", {
  f <- .sr_tile(.sr_m(), scale = 1e-4, offset = -0.1)
  meta <- gdal_grid_spec(f)
  expect_identical(meta$scale, 1e-4)
  expect_identical(meta$offset, -0.1)
  f2 <- .sr_tile(.sr_m())
  meta2 <- gdal_grid_spec(f2)
  expect_identical(meta2$scale, numeric(0))
  expect_identical(meta2$offset, numeric(0))
})

test_that("scale = TRUE applies the discovered affine after sentinel -> NaN", {
  m <- .sr_m()
  f <- .sr_tile(m, scale = 1e-4, offset = -0.1)
  x <- lazy_source(f, scale = TRUE)
  expect_identical(x@grid@dtype, "f32")      # affine promotes like nodata (D8)
  got <- matrix(collect(x), nrow = 20)
  ref <- m; ref[3, 4] <- NaN; ref <- ref * 1e-4 - 0.1
  expect_identical(is.nan(got), is.nan(ref)) # sentinel stayed NaN, never scaled
  expect_equal(got, ref, tolerance = 1e-6)
})

test_that("default reads stay raw; explicit numeric scale applies", {
  m <- .sr_m()
  f <- .sr_tile(m, scale = 1e-4, offset = -0.1)
  ref0 <- m; ref0[3, 4] <- NaN
  expect_equal(matrix(collect(lazy_source(f)), nrow = 20), ref0)
  got <- matrix(collect(lazy_source(f, scale = 2, offset = 5)), nrow = 20)
  expect_equal(got, ref0 * 2 + 5)
  # identity affine normalises to absent
  x <- lazy_source(f, scale = 1, offset = 0)
  expect_identical(graph_get(x@graph, x@node_id)@scale, numeric(0))
})

test_that("the file form keys a named scale and offset by band", {
  f <- system.file("extdata", "garry-example.tif", package = "garry")
  raw <- lazy_dataset(f)
  read <- function(x) as.numeric(collect(x, distributed = FALSE))
  ds <- lazy_dataset(f, scale = c(nir = 0.5))
  expect_equal(read(ds$nir), read(raw$nir) * 0.5)
  expect_equal(read(ds$red), read(raw$red))         # no key: no scale
  ds <- lazy_dataset(f, scale = c(nir = 0.5, red = 2), offset = c(nir = 1))
  expect_equal(read(ds$nir), read(raw$nir) * 0.5 + 1, tolerance = 1e-6)
  expect_equal(read(ds$red), read(raw$red) * 2)     # no key: no offset
  ds <- lazy_dataset(f, scale = c(red = 2), offset = c(nir = 1))
  expect_equal(read(ds$nir), read(raw$nir) + 1, tolerance = 1e-6) # scale 1
  expect_error(lazy_dataset(f, scale = c(nirr = 0.5)), "nirr",
               class = "garry_source_error")
  expect_error(lazy_dataset(f, scale = NA_real_), "finite")
  expect_error(lazy_dataset(f, scale = 2, offset = Inf), "finite")
})

test_that("scale = TRUE without file metadata warns and reads raw", {
  m <- .sr_m()
  f <- .sr_tile(m)
  expect_warning(x <- lazy_source(f, scale = TRUE), "no scale/offset", class = "garry_scale_warning")
  ref0 <- m; ref0[3, 4] <- NaN
  expect_equal(matrix(collect(x), nrow = 20), ref0)
})

# -- composite_direct: the affine rides the job, applied to the DN cube ------

.sr_scaled_composite <- function(scaleA = 1e-4, offsetA = -0.1,
                                 scaleB = scaleA, offsetB = offsetA,
                                 single = FALSE) {
  gA <- .gg_gti(list(s1 = .gg_val(0),   s2 = .gg_val(10)))
  gB <- .gg_gti(list(s1 = .gg_val(100), s2 = .gg_val(50)))
  qa1 <- matrix(0, 40, 60); qa1[10:20, 10:30] <- 2
  qa2 <- matrix(0, 40, 60); qa2[25:35, 40:55] <- 2
  gQ <- .gg_gti(list(s1 = qa1, s2 = qa2))
  g <- graph_new()
  sl <- function(gti, s, sc, of) lazy_source(
    paste0("GTI:", gti), graph = g,
    open_options = gti_open_options(.gg_grid,
                                    filter = sprintf("slice = '%s'", s),
                                    sort_field = "datetime"),
    grid = .gg_grid, block_dim = c(60L, 40L), scale = sc, offset = of)
  vars <- list(
    V1 = list(s1 = sl(gA, "s1", scaleA, offsetA),
              s2 = sl(gA, "s2", scaleA, offsetA)),
    V2 = list(s1 = sl(gB, "s1", scaleB, offsetB),
              s2 = sl(gB, "s2", scaleB, offsetB)),
    Q  = list(s1 = .gg_slice(gQ, "s1", g), s2 = .gg_slice(gQ, "s2", g))
  )
  if (single) vars$V2 <- NULL
  ds <- as_dataset(vars, mask_asset = "Q")
  reduce_over(apply_mask(ds, where = c(2)), "median", "t", nan_rm = TRUE)
}

local({
  local_pools(2, 1)

  test_that("composite_direct applies the read affine on the cube path", {
    x <- .sr_scaled_composite()
    p <- collect(x, plan_only = TRUE)
    spec <- .cd_spec(p)
    expect_false(is.null(spec))                 # affine keeps the fast path eligible
    expect_identical(spec$band_affine[[1L]]$scale, 1e-4)
    # the multi-band pipeline, then a single band's whole-grid kernel
    for (single in c(FALSE, TRUE)) {
      y <- .sr_scaled_composite(single = single)
      want <- .gg_masked_want(single = single) * 1e-4 - 0.1
      .gg_close(collect(y, distributed = FALSE), want) # the read scales on the host
      got <- collect(y, distributed = TRUE)
      expect_identical(garry_last_route(), "composite_direct")
      .gg_close(got, want)
    }
  })

  test_that("per-slice heterogeneous affine falls through, identically", {
    gA <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(10)))
    g <- graph_new()
    sl <- function(s, sc) lazy_source(
      paste0("GTI:", gA), graph = g,
      open_options = gti_open_options(.gg_grid,
                                      filter = sprintf("slice = '%s'", s),
                                      sort_field = "datetime"),
      grid = .gg_grid, block_dim = c(60L, 40L), scale = sc, offset = 0.5)
    x <- reduce_over(lazy_stack(list(sl("s1", 1e-4), sl("s2", 2e-4))),
                     "median", "t", nan_rm = TRUE)
    p <- collect(x, plan_only = TRUE)
    expect_null(.cd_spec(p))                    # heterogeneous slices: ineligible
    want <- (.gg_val(0) * 1e-4 + 0.5 + .gg_val(10) * 2e-4 + 0.5) / 2
    .gg_close(collect(x, distributed = FALSE), want)
    .gg_close(collect(x, distributed = TRUE), want) # whatever route it lands on
  })
})
