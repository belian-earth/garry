# Warper bypass: an aligned same-CRS warp is served by a decimating
# RasterIO read instead of a warped VRT. The fast path is only ever a
# speed change, so every test here pins it to the warper's answer.

# Force the warper for `expr`, whatever the predicate says.
with_warper <- function(expr) {
  ns <- asNamespace("garry")
  orig <- get(".rio_direct_spec", envir = ns)
  unlockBinding(".rio_direct_spec", ns)
  assign(".rio_direct_spec", function(...) NULL, envir = ns)
  on.exit({
    assign(".rio_direct_spec", orig, envir = ns)
    lockBinding(".rio_direct_spec", ns)
  })
  force(expr)
}

# Target grid `fact`-times coarser than `g`, anchored on its origin.
coarser <- function(g, fact, nx, ny, ...) {
  r <- g@transform[[2L]] * fact
  x0 <- g@transform[[1L]]
  y0 <- g@transform[[4L]]
  grid_spec(g@crs,
            extent = c(x0, y0 - ny * r, x0 + nx * r, y0),
            dims = c(nx, ny), ...)
}

test_that("aligned same-CRS warps take the fast path", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid

  expect_false(is.null(.rio_direct_spec(f, coarser(g, 2L, 20L, 15L), "average")))
  expect_false(is.null(.rio_direct_spec(f, coarser(g, 1L, 30L, 20L), "near")))

  spec <- .rio_direct_spec(f, coarser(g, 2L, 20L, 15L), "average")
  expect_identical(spec$fx, 2L)
  expect_identical(spec$fy, 2L)
  expect_identical(spec$x_off, 0L)
  expect_identical(spec$y_off, 0L)
  expect_identical(spec$resamp, "AVERAGE")
})

test_that("the fast path refuses anything the warper is needed for", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  r <- g@transform[[2L]]
  x0 <- g@transform[[1L]]
  y0 <- g@transform[[4L]]
  ok <- coarser(g, 2L, 20L, 15L)

  # non-integer pixel ratio
  expect_null(.rio_direct_spec(
    f,
    grid_spec(g@crs, extent = c(x0, y0 - 15 * r * 1.5, x0 + 20 * r * 1.5, y0),
              dims = c(20L, 15L)),
    "average"
  ))
  # origin off the source pixel grid
  expect_null(.rio_direct_spec(
    f,
    grid_spec(g@crs,
              extent = c(x0 + r / 3, y0 - 15 * 2 * r, x0 + r / 3 + 20 * 2 * r, y0),
              dims = c(20L, 15L)),
    "average"
  ))
  # upsampling
  expect_null(.rio_direct_spec(
    f,
    grid_spec(g@crs, extent = c(x0, y0 - 15 * r / 2, x0 + 20 * r / 2, y0),
              dims = c(20L, 15L)),
    "average"
  ))
  # target runs past the source edge
  expect_null(.rio_direct_spec(
    f,
    grid_spec(g@crs, extent = c(x0 - 100 * r, y0 - 15 * 2 * r, x0 + 20 * 2 * r, y0),
              dims = c(120L, 15L)),
    "average"
  ))
  # a different CRS genuinely needs warping
  expect_null(.rio_direct_spec(
    f,
    grid_spec("EPSG:4326", extent = c(0, 0, 1, 1), dims = c(20L, 15L)),
    "average"
  ))
  # open options are left to the warper in v1
  expect_null(.rio_direct_spec(f, ok, "average", "OVERVIEW_LEVEL=NONE"))
  # resampling with no RasterIO analogue
  expect_null(.rio_direct_spec(f, ok, "med"))
  # multi-band request: the decimating read is single-band
  expect_null(.rio_direct_spec(f, ok, "average", band = 1:2))

  # integer band + interpolating resampler: RasterIO and the warper
  # round .5 ties oppositely on ARM under GDAL 3.13.1, so identity only
  # holds for NEAREST there (see .rio_direct_spec())
  fi <- fixture_i16_nodata()
  gi <- gdal_grid_spec(fi)$grid
  expect_null(.rio_direct_spec(fi, coarser(gi, 2L, 20L, 15L), "average"))
  expect_false(is.null(.rio_direct_spec(fi, coarser(gi, 1L, 20L, 15L), "near")))
})

test_that("fast-path reads equal warped-VRT reads", {
  # every combination the fast path accepts: interpolating resamplers
  # only reach it for float bands (integer + average is refused, see
  # the gate test above), so i16 is exercised at NEAREST
  cases <- list(
    list(f = fixture_gradient_f32(), fact = 1L, resampling = "near"),
    list(f = fixture_gradient_f32(), fact = 2L, resampling = "average"),
    list(f = fixture_i16_nodata(), fact = 1L, resampling = "near")
  )
  for (case in cases) {
    f <- case$f
    g <- gdal_grid_spec(f)$grid
    nd <- gdal_grid_spec(f)$nodata
    target <- coarser(g, case$fact, 20L, 15L)
    spec <- .rio_direct_spec(f, target, case$resampling)
    expect_false(is.null(spec))

    # name the iteration so a platform-specific failure identifies
    # its fixture/factor/resampling in the check log
    tag <- paste0(basename(f), " fact=", case$fact, " ", case$resampling)
    fast <- gdal_read_window(f, 1L, 0L, 0L, 20L, 15L, nodata = nd,
                             decim = spec)
    vrt <- gdal_warp_vrt(f, 1L, target, case$resampling, src_nodata = nd)
    want <- gdal_read_window(vrt, 1L, 0L, 0L, 20L, 15L, nodata = nd)
    expect_equal(fast, want,
                 label = paste0("fast [", tag, "]"),
                 expected.label = "warped-VRT read")

    # an offset window inside the same grid exercises the translation
    fast2 <- gdal_read_window(f, 1L, 3L, 2L, 10L, 8L, nodata = nd,
                              decim = spec)
    want2 <- gdal_read_window(vrt, 1L, 3L, 2L, 10L, 8L, nodata = nd)
    expect_equal(fast2, want2,
                 label = paste0("offset fast [", tag, "]"),
                 expected.label = "warped-VRT read")
  }
})

test_that("an aligned align_to() pipeline is unchanged by the fast path", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  target <- coarser(g, 2L, 30L, 20L)
  # the fast path must actually be in play for this to prove anything
  expect_false(is.null(.rio_direct_spec(f, target, "average")))

  expr <- function() align_to(lazy_source(f), target, resampling = "average") * 2 + 1
  got <- collect(expr())
  want <- with_warper(collect(expr()))

  expect_identical(got, want)
  expect_identical(dim(got), c(20L, 30L))
})

test_that("a warp needing reprojection still builds a VRT", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(30L, 20L))

  calls <- 0L
  ns <- asNamespace("garry")
  orig <- get("gdal_warp_vrt", envir = ns)
  unlockBinding("gdal_warp_vrt", ns)
  assign("gdal_warp_vrt",
         function(...) {
           calls <<- calls + 1L
           orig(...)
         },
         envir = ns)
  on.exit({
    assign("gdal_warp_vrt", orig, envir = ns)
    lockBinding("gdal_warp_vrt", ns)
  })

  collect(align_to(lazy_source(f), target))
  expect_gt(calls, 0L)
})

# A Float32 raster in UTM 37N south of the equator (negative northings),
# as an OlmoEarth store lays out the southern hemisphere, with nodata.
.utm_n_south <- function() {
  f <- file.path(tempdir(), "garry-utm37n-south.tif")
  if (!file.exists(f)) {
    set.seed(3)
    ds <- gdalraster::create(
      "GTiff",
      f,
      60L,
      40L,
      1L,
      "Float32",
      return_obj = TRUE
    )
    ds$setGeoTransform(c(500000, 10, 0, -1000000, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32637"))
    v <- stats::runif(2400L, -50, 50)
    v[sample(2400L, 100L)] <- -9999
    ds$setNoDataValue(1L, -9999)
    ds$write(1L, 0L, 0L, 60L, 40L, v)
    ds$close()
  }
  f
}

# Its cells on the zone's southern grid (northings + 10,000 km): 7 px
# in, 5 px down, at `fact` times the source pixel, moved `dx` m east.
.utm_s_grid <- function(fact = 1L, dx = 0) {
  te <- c(500070 + dx, 9e6 - 50 - 240, 500070 + dx + 400, 9e6 - 50)
  grid_spec(
    "EPSG:32737",
    extent = te,
    dims = c(x = 40L %/% fact, y = 24L %/% fact)
  )
}

test_that("CRSs that differ only by their false origin are a shift apart", {
  expect_identical(
    .crs_false_origin_shift("EPSG:32637", "EPSG:32737"),
    c(0, 1e7)
  )
  expect_identical(
    .crs_false_origin_shift("EPSG:32737", "EPSG:32637"),
    c(0, -1e7)
  )
  expect_identical(.crs_false_origin_shift("EPSG:32637", "EPSG:32637"), c(0, 0))
  tm <- "+proj=tmerc +lat_0=0 +lon_0=39 +k=0.9996 +x_0=500000 +y_0=0 +datum=WGS84 +units=m"
  expect_identical(
    .crs_false_origin_shift(tm, sub("x_0=500000", "x_0=250000", tm)),
    c(-250000, 0)
  )
  expect_null(.crs_false_origin_shift("EPSG:32637", "EPSG:32638")) # next zone
  expect_null(.crs_false_origin_shift("EPSG:32637", "EPSG:20137")) # Adindan datum
  expect_null(.crs_false_origin_shift("EPSG:4326", "EPSG:32637")) # no false origin
})

test_that("a target on the source's southern UTM grid reads directly", {
  f <- .utm_n_south()
  spec <- .rio_direct_spec(f, .utm_s_grid(), "near")
  expect_identical(
    spec[c("fx", "fy", "x_off", "y_off")],
    list(fx = 1L, fy = 1L, x_off = 7L, y_off = 5L)
  )
  expect_false(is.null(.rio_direct_spec(f, .utm_s_grid(2L), "near")))
  # interpolators keep the warper: its reads through the shift change
  # with the GDAL version (3.11 does not return the source cells)
  for (r in c("bilinear", "cubic", "average")) {
    expect_null(.rio_direct_spec(f, .utm_s_grid(), r))
  }
  # off the source's pixel grid is a genuine warp
  expect_null(.rio_direct_spec(f, .utm_s_grid(dx = 5), "near"))
  for (case in list(list("near", 1L), list("near", 2L))) {
    expr <- function() {
      align_to(lazy_source(f), .utm_s_grid(case[[2L]]), resampling = case[[1L]])
    }
    expect_identical(
      collect(expr(), distributed = FALSE),
      with_warper(collect(expr(), distributed = FALSE)),
      label = paste(case[[1L]], "x", case[[2L]])
    )
  }
})

test_that("a northern-zone Zarr year writes onto its southern grid as the warper does", {
  skip_on_cran()
  skip_if_not_installed("jsonlite")
  fx <- fixture_zarr_nd(epsg = 32637L, y1 = -1000000)
  # the store's first 20 x 12 px, nodata corner included
  g <- grid_spec("EPSG:32737", c(500000, 9e6 - 120, 500200, 9e6), res = 10)
  yr <- stack_bands(time_sel(lazy_dataset(fx$path, g), "2023"))
  p <- plan_lazy(yr)
  ws <- Filter(function(s) s@kind == "warp", p@stages)[[1L]]
  expect_false(is.null(.stage_read_args(p@graph, ws)$decim$fx))
  got <- collect(yr, distributed = FALSE)
  for (b in 1:4) {
    ref <- fx$vals[3L, b, 1:12, 1:20] * 1.0
    ref[ref == -128] <- NaN
    expect_equal(unname(got[,, b]), ref)
  }
  expect_identical(got, with_warper(collect(yr, distributed = FALSE)))
  # pooled and single-process i8 writes, the pooled one reading straight
  # into integer planes
  local_pools(2, 1)
  f1 <- withr::local_tempfile(fileext = ".tif")
  f2 <- withr::local_tempfile(fileext = ".tif")
  write_tif(yr, f1, dtype = "i8", nodata = -128L, distributed = TRUE)
  with_warper(write_tif(
    yr,
    f2,
    dtype = "i8",
    nodata = -128L,
    distributed = FALSE
  ))
  bands <- function(f) {
    ds <- methods::new(gdalraster::GDALRaster, f)
    on.exit(ds$close())
    lapply(1:4, function(b) ds$read(b, 0L, 0L, 20L, 12L, 20L, 12L))
  }
  expect_identical(bands(f1), bands(f2))
  expect_identical(bands(f1)[[1L]][[1L]], NA_integer_)
})
