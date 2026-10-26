# Warper bypass: an aligned same-CRS warp is served by a decimating
# RasterIO read instead of a warped VRT. The fast path is only ever a
# speed change, so every test here pins it to the warper's answer.

# Force the warper for `expr`, whatever the predicates say: no direct
# read of a source, and several sources warped together.
with_warper <- function(expr) {
  ns <- asNamespace("garry")
  fns <- c(".rio_direct_spec", ".mosaic_read_spec")
  orig <- lapply(fns, get, envir = ns)
  for (f in fns) {
    unlockBinding(f, ns)
    assign(f, function(...) NULL, envir = ns)
  }
  on.exit(
    for (i in seq_along(fns)) {
      assign(fns[[i]], orig[[i]], envir = ns)
      lockBinding(fns[[i]], ns)
    }
  )
  force(expr)
}

# Is every part of a mosaic spec warped (TRUE), or read directly?
.warped <- function(spec) vapply(spec$parts, function(p) isTRUE(p$warp), NA)

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

# Two south-up Int16 tiles (positive y pixel size, as AEF stores them),
# `nb` bands of distinct values, nodata -1 on the first cells of each
# tile's southern row; the second overlaps the first by two columns,
# so its nodata cells there show the first through.
.south_up_tiles <- function(nb = 2L) {
  dir <- file.path(tempdir(), paste0("garry-south-up-", nb))
  dir.create(dir, showWarnings = FALSE)
  mk <- function(name, x0, seed) {
    f <- file.path(dir, name)
    if (!file.exists(f)) {
      ds <- gdalraster::create(
        "GTiff",
        f,
        6L,
        5L,
        nb,
        "Int16",
        return_obj = TRUE
      )
      ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
      ds$setGeoTransform(c(x0, 10, 0, 8600000, 0, 10))
      for (b in seq_len(nb)) {
        v <- seed * 1000L + b * 100L + seq_len(30L)
        v[1:3] <- -1L # file row 1 is the southern row
        ds$setNoDataValue(b, -1)
        ds$write(b, 0L, 0L, 6L, 5L, v)
      }
      ds$close()
    }
    f
  }
  c(mk("a.tif", 500000, 1L), mk("b.tif", 500040, 2L))
}

# The tiles' 10 m grid, one pixel wider than both on every side.
.south_up_grid <- function(res = 10) {
  grid_spec("EPSG:32736", c(499990, 8599990, 500110, 8600060), res = res)
}

test_that("a south-up source on its own pixels reads directly, rows flipped", {
  f <- .south_up_tiles(1L)[[1L]]
  sub <- grid_spec("EPSG:32736", c(500010, 8600010, 500050, 8600040), res = 10)
  spec <- .rio_direct_spec(f, sub, "near")
  expect_identical(
    spec[c("fx", "fy", "x_off", "y_off", "flip")],
    list(fx = 1L, fy = 1L, x_off = 1L, y_off = 1L, flip = TRUE)
  )
  # a decimating read of it keeps the warper
  sub20 <- grid_spec(
    "EPSG:32736",
    c(500000, 8600010, 500040, 8600050),
    res = 20
  )
  expect_null(.rio_direct_spec(f, sub20, "near"))
  expect_null(.rio_direct_spec(f, sub, "bilinear"))
  for (g in list(sub, sub20)) {
    expr <- function() lazy_dataset(f, g, resampling = "near")
    got <- collect(stack_bands(expr()), distributed = FALSE)
    expect_identical(
      got,
      with_warper(collect(stack_bands(expr()), distributed = FALSE))
    )
  }
  yr <- stack_bands(lazy_dataset(f, sub, resampling = "near"))
  p <- plan_lazy(yr)
  ws <- Filter(function(s) s@kind == "warp", p@stages)[[1L]]
  expect_true(.stage_read_args(p@graph, ws)$decim$flip)
  got <- collect(yr, distributed = FALSE)
  # row 1 is the target's northern row: the file's fourth from the
  # south, columns 2 to 5
  expect_identical(as.vector(got[1L, ]), c(1120, 1121, 1122, 1123))
  # the pooled integer write reads straight into flipped integer planes
  local_pools(1, 1)
  f1 <- withr::local_tempfile(fileext = ".tif")
  f2 <- withr::local_tempfile(fileext = ".tif")
  write_tif(yr, f1, dtype = "i16", nodata = -1L, distributed = TRUE)
  with_warper(write_tif(
    yr,
    f2,
    dtype = "i16",
    nodata = -1L,
    distributed = FALSE
  ))
  rd <- function(f) {
    d <- methods::new(gdalraster::GDALRaster, f)
    on.exit(d$close())
    d$read(1L, 0L, 0L, 4L, 3L, 4L, 3L)
  }
  expect_identical(rd(f1), rd(f2))
})

test_that("south-up tiles no mosaic can hold read directly, tile by tile", {
  tiles <- .south_up_tiles(2L)
  g <- .south_up_grid()
  spec <- .mosaic_read_spec(tiles, g, band = 1:2, nodata = -1)
  expect_length(spec$parts, 2L)
  expect_false(any(.warped(spec)))
  expect_identical(vapply(spec$parts, `[[`, integer(1), "x_off"), c(-1L, -5L))
  expect_identical(vapply(spec$parts, `[[`, integer(1), "y_off"), c(-1L, -1L))
  # a source off the target's pixels, with another nodata, or in another
  # projection is warped alone
  expect_true(all(.warped(.mosaic_read_spec(tiles, .south_up_grid(20), 1L))))
  expect_true(all(.warped(.mosaic_read_spec(tiles, g, 1L, nodata = -2))))
  other <- file.path(tempdir(), "garry-south-up-other.tif")
  gdalraster::warp(
    tiles[[2L]],
    other,
    t_srs = "EPSG:32735",
    cl_arg = c("-r", "near"),
    quiet = TRUE
  )
  expect_identical(
    .warped(.mosaic_read_spec(c(tiles[[1L]], other), g, 1L)),
    c(FALSE, TRUE)
  )
  # an interpolating read warps them together
  p_bil <- plan_lazy(stack_bands(lazy_dataset(
    tiles,
    g,
    resampling = "bilinear"
  )))
  w_bil <- Filter(function(s) s@kind == "warp", p_bil@stages)[[1L]]
  expect_null(.stage_read_args(p_bil@graph, w_bil)$decim)

  ds <- function() lazy_dataset(tiles, g, resampling = "near")
  p <- plan_lazy(stack_bands(ds()))
  ws <- Filter(function(s) s@kind == "warp", p@stages)[[1L]]
  expect_length(.stage_read_args(p@graph, ws)$decim$parts, 2L)
  # windows of 3 x 3 px straddle the tiles, their overlap and the margin
  for (px in c(9, 1e6)) {
    withr::local_options(garry.chunk_target_px = px)
    got <- collect(stack_bands(ds()), distributed = FALSE)
    expect_identical(
      got,
      with_warper(collect(stack_bands(ds()), distributed = FALSE))
    )
  }
  # the margin is NaN; in the overlap (columns 6 and 7) the second tile
  # wins where valid and shows the first through its nodata
  b1 <- got[,, 1L]
  expect_true(all(is.nan(c(b1[1L, ], b1[7L, ], b1[, 1L], b1[, 12L]))))
  expect_identical(
    b1[6L, 2:11],
    c(NaN, NaN, NaN, 1104, 1105, 1106, NaN, 2104, 2105, 2106)
  )
  expect_identical(b1[2L, 6:7], c(2125, 2126))

  # the pooled i16 write matches the warper's
  local_pools(2, 1)
  f1 <- withr::local_tempfile(fileext = ".tif")
  f2 <- withr::local_tempfile(fileext = ".tif")
  withr::local_options(garry.chunk_target_px = 9)
  write_tif(ds(), f1, dtype = "i16", nodata = -1L, distributed = TRUE)
  with_warper(write_tif(
    ds(),
    f2,
    dtype = "i16",
    nodata = -1L,
    distributed = FALSE
  ))
  bands <- function(f) {
    d <- methods::new(gdalraster::GDALRaster, f)
    on.exit(d$close())
    lapply(1:2, function(b) d$read(b, 0L, 0L, 12L, 7L, 12L, 7L))
  }
  expect_identical(bands(f1), bands(f2))
})

test_that("rows flip and mosaic parts paste in C", {
  v <- 1:6
  expect_identical(
    .Call("garry_flip_rows", v, 3, 2, PACKAGE = "garry"),
    c(5L, 6L, 3L, 4L, 1L, 2L)
  )
  expect_identical(
    .Call("garry_flip_rows", as.numeric(v), 2, 3, PACKAGE = "garry"),
    c(4, 5, 6, 1, 2, 3)
  )
  expect_error(
    .Call("garry_flip_rows", v, 4, 2, PACKAGE = "garry"),
    "do not hold"
  )
  f32 <- function(x) writeBin(as.numeric(x), raw(), size = 4L)
  # a 2-band 3 x 2 window, NaN to start; a 2 x 1 part at column 1, row 1
  buf <- .Call(
    "garry_paste_f32",
    NULL,
    raw(0),
    c(2, 3, 2, 0, 0, 0, 0),
    PACKAGE = "garry"
  )
  expect_true(all(is.nan(readBin(buf, "numeric", 12L, size = 4L))))
  .Call(
    "garry_paste_f32",
    buf,
    f32(c(7, NaN, 8, 9)),
    c(2, 3, 2, 1, 1, 2, 1),
    PACKAGE = "garry"
  )
  expect_identical(
    readBin(buf, "numeric", 12L, size = 4L),
    c(NaN, NaN, NaN, NaN, 7, NaN, NaN, NaN, NaN, NaN, 8, 9)
  )
  expect_error(
    .Call(
      "garry_paste_f32",
      buf,
      f32(1:4),
      c(2, 3, 2, 2, 1, 2, 1),
      PACKAGE = "garry"
    ),
    "does not fit"
  )
})

# Two Float32 south-up tiles overlapping by two columns, nodata -9999;
# the second holds NaN values in the overlap.
.float_tiles <- function() {
  dir <- file.path(tempdir(), "garry-float-tiles")
  dir.create(dir, showWarnings = FALSE)
  mk <- function(name, x0, v) {
    f <- file.path(dir, name)
    if (!file.exists(f)) {
      ds <- gdalraster::create(
        "GTiff",
        f,
        6L,
        5L,
        1L,
        "Float32",
        return_obj = TRUE
      )
      ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
      ds$setGeoTransform(c(x0, 10, 0, 8600000, 0, 10))
      ds$setNoDataValue(1L, -9999)
      ds$write(1L, 0L, 0L, 6L, 5L, v)
      ds$close()
    }
    f
  }
  vb <- 200 + seq_len(30)
  vb[c(1, 2, 7, 8)] <- NaN # file columns 0 and 1: the overlap
  c(mk("a.tif", 500000, 100 + seq_len(30)), mk("b.tif", 500040, vb))
}

test_that("tiles in two projections read source by source as the warper reads them", {
  tiles <- .south_up_tiles(2L)
  other <- file.path(tempdir(), "garry-south-up-other.tif")
  if (!file.exists(other)) {
    gdalraster::warp(
      tiles[[2L]],
      other,
      t_srs = "EPSG:32735",
      cl_arg = c("-r", "near"),
      quiet = TRUE
    )
  }
  ds <- function() {
    lazy_dataset(c(tiles[[1L]], other), .south_up_grid(), resampling = "near")
  }
  for (px in c(9, 1e6)) {
    withr::local_options(garry.chunk_target_px = px)
    expect_identical(
      collect(stack_bands(ds()), distributed = FALSE),
      with_warper(collect(stack_bands(ds()), distributed = FALSE))
    )
  }
  # under the exact transformer a nearest warp takes the same cells
  # whatever window it is given, and the source-by-source read with it
  withr::local_options(garry.warp_exact = TRUE)
  for (px in c(9, 1e6)) {
    withr::local_options(garry.chunk_target_px = px)
    expect_identical(
      collect(stack_bands(ds()), distributed = FALSE),
      with_warper(collect(stack_bands(ds()), distributed = FALSE))
    )
  }
  g <- .south_up_grid()
  whole <- gdal_warp_window(other, 1L, g, 0L, 0L, 12L, 7L, nodata = -1)
  halves <- cbind(
    gdal_warp_window(other, 1L, g, 0L, 0L, 5L, 7L, nodata = -1),
    gdal_warp_window(other, 1L, g, 5L, 0L, 7L, 7L, nodata = -1)
  )
  expect_identical(whole, halves)
})

test_that("a masked source keeps the warper, and a mosaic warps it alone", {
  tiles <- .south_up_tiles(1L)
  g <- .south_up_grid()
  masked <- file.path(tempdir(), "garry-south-up-masked.tif")
  if (!file.exists(masked)) {
    # its nodata becomes an internal mask the warper honours
    gdalraster::translate(
      tiles[[2L]],
      masked,
      cl_arg = c("-a_nodata", "none", "-mask", "1"),
      quiet = TRUE
    )
  }
  expect_null(.rio_direct_spec(masked, g, "near", partial = TRUE))
  expect_identical(
    .warped(.mosaic_read_spec(c(tiles[[1L]], masked), g, 1L)),
    c(FALSE, TRUE)
  )
  ds <- function() lazy_dataset(c(tiles[[1L]], masked), g, resampling = "near")
  expect_identical(
    collect(stack_bands(ds()), distributed = FALSE),
    with_warper(collect(stack_bands(ds()), distributed = FALSE))
  )
})

test_that("overlapping float tiles keep the warper unless their nodata is NaN", {
  tiles <- .float_tiles()
  g <- .south_up_grid()
  # the warper lets the second tile's NaN cover the first's values
  expect_null(.mosaic_read_spec(tiles, g, 1L, nodata = -9999))
  expect_false(is.null(.mosaic_read_spec(tiles, g, 1L, nodata = NaN)))
  ds <- function() lazy_dataset(tiles, g, resampling = "near")
  expect_identical(
    collect(stack_bands(ds()), distributed = FALSE),
    with_warper(collect(stack_bands(ds()), distributed = FALSE))
  )
})

test_that("a node nodata over a south-up file's own keeps the warper", {
  f <- .south_up_tiles(1L)[[1L]]
  sub <- grid_spec("EPSG:32736", c(500010, 8600010, 500050, 8600040), res = 10)
  expect_null(.rio_direct_spec(f, sub, "near", nodata = -2))
  expect_false(is.null(.rio_direct_spec(f, sub, "near", nodata = -1)))
})

test_that("a mosaic read gives f32 values whatever the window", {
  dir <- file.path(tempdir(), "garry-f64-tiles")
  dir.create(dir, showWarnings = FALSE)
  mk <- function(name, x0) {
    f <- file.path(dir, name)
    if (!file.exists(f)) {
      ds <- gdalraster::create(
        "GTiff",
        f,
        6L,
        5L,
        1L,
        "Float64",
        return_obj = TRUE
      )
      ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
      ds$setGeoTransform(c(x0, 10, 0, 8600000, 0, 10))
      ds$write(1L, 0L, 0L, 6L, 5L, 20.1 + seq_len(30))
      ds$close()
    }
    f
  }
  tiles <- c(mk("a.tif", 500000), mk("b.tif", 500060))
  ds <- function() lazy_dataset(tiles, .south_up_grid(), resampling = "near")
  withr::local_options(garry.chunk_target_px = 4)
  small <- collect(stack_bands(ds()), distributed = FALSE)
  withr::local_options(garry.chunk_target_px = 1e6)
  expect_identical(small, collect(stack_bands(ds()), distributed = FALSE))
})

test_that("several sources on their own grid read source by source", {
  tiles <- .south_up_tiles(2L)
  ds <- function() lazy_dataset(tiles, resampling = "near")
  p <- plan_lazy(stack_bands(ds()))
  rs <- Filter(function(s) s@kind == "source_read", p@stages)[[1L]]
  expect_length(.stage_read_args(p@graph, rs)$decim$parts, 2L)
  expect_identical(
    collect(stack_bands(ds()), distributed = FALSE),
    with_warper(collect(stack_bands(ds()), distributed = FALSE))
  )
})

test_that("a multi-band warp masks each band's nodata alone", {
  f <- file.path(tempdir(), "garry-band-nodata.tif")
  if (!file.exists(f)) {
    ds <- gdalraster::create(
      "GTiff",
      f,
      4L,
      3L,
      2L,
      "Int16",
      options = "INTERLEAVE=PIXEL",
      return_obj = TRUE
    )
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32736"))
    ds$setGeoTransform(c(500000, 10, 0, 8600030, 0, -10))
    v1 <- seq_len(12)
    v1[2] <- -1L
    v2 <- seq_len(12) + 100L
    v2[7] <- -1L
    ds$setNoDataValue(1L, -1)
    ds$setNoDataValue(2L, -1)
    ds$write(1L, 0L, 0L, 4L, 3L, v1)
    ds$write(2L, 0L, 0L, 4L, 3L, v2)
    ds$close()
  }
  g <- grid_spec(
    "EPSG:32735",
    gdalraster::transform_bounds(
      c(500000, 8600000, 500040, 8600030),
      "EPSG:32736",
      "EPSG:32735"
    ),
    res = 10
  )
  both <- gdal_warp_window(
    f,
    1:2,
    g,
    0L,
    0L,
    g@dims[["x"]],
    g@dims[["y"]],
    nodata = -1
  )
  one <- gdal_warp_window(
    f,
    2L,
    g,
    0L,
    0L,
    g@dims[["x"]],
    g@dims[["y"]],
    nodata = -1
  )
  expect_identical(both[2L, , ], one)
  expect_false(any(both == -1, na.rm = TRUE))
})
