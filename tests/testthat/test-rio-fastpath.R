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

test_that("an aligned align() pipeline is unchanged by the fast path", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  target <- coarser(g, 2L, 30L, 20L)
  # the fast path must actually be in play for this to prove anything
  expect_false(is.null(.rio_direct_spec(f, target, "average")))

  expr <- function() align(lazy_source(f), target, resampling = "average") * 2 + 1
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

  collect(align(lazy_source(f), target))
  expect_gt(calls, 0L)
})
