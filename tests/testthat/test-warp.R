# Phase 4b gate: warp = lazy VRT, GDAL owns cross-CRS pixel math (D5).
# terra::project (also GDAL underneath) is the independent reference.
#
# Target grids use dims that do NOT align target pixel centres with
# source cell edges; nearest-neighbour comparisons still allow a <=2%
# disagreement for residual boundary ties (both engines are GDAL, but
# tie-breaking at exact cell boundaries is not contractual).

skip_if_not_installed("anvl")

.warp_target <- function(dims = c(71L, 47L)) {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  grid_spec("EPSG:4326", extent = b, dims = dims)
}

.terra_template <- function(target) {
  terra::rast(nrows = target@dims[["y"]], ncols = target@dims[["x"]],
              extent = terra::ext(target@extent[c(1, 3, 2, 4)]),
              crs = "EPSG:4326")
}

test_that("align + collect matches terra::project (bilinear)", {
  skip_if_not_installed("terra")
  f <- fixture_gradient_f32()
  target <- .warp_target()
  a <- lazy_source(f)
  got <- collect(align(a, target, resampling = "bilinear"))
  want <- as.matrix(
    terra::project(terra::rast(f), .terra_template(target),
                   method = "bilinear"), wide = TRUE)

  # NaN footprints agree almost everywhere (edge cells may differ).
  expect_gt(mean(is.nan(got) == is.na(want)), 0.98)
  ok <- !is.nan(got) & !is.na(want)
  expect_gt(mean(ok), 0.5)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("align + collect matches terra::project (nearest, tie-tolerant)", {
  skip_if_not_installed("terra")
  f <- fixture_gradient_f32()
  target <- .warp_target()
  a <- lazy_source(f)
  got <- collect(align(a, target, resampling = "nearest"))
  want <- as.matrix(
    terra::project(terra::rast(f), .terra_template(target),
                   method = "near"), wide = TRUE)

  ok <- !is.nan(got) & !is.na(want)
  expect_gt(mean(ok), 0.5)
  agree <- got[ok] == want[ok]
  expect_gt(mean(agree), 0.98)
  # Disagreements are boundary ties: one source cell apart at most.
  if (any(!agree)) {
    d <- abs(got[ok][!agree] - want[ok][!agree])
    expect_true(all(d %in% c(1, 99, 100, 101)))
  }
})

test_that("warp is chunk-invariant (VRT window reads == whole warp)", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  w <- align(a, .warp_target(), resampling = "bilinear")

  old <- options(garry.chunk_target_px = 1e6)
  whole <- collect(w)
  options(garry.chunk_target_px = 17 * 13)
  chunked <- collect(w)
  options(old)
  expect_identical(is.nan(chunked), is.nan(whole))
  ok <- !is.nan(whole)
  expect_equal(chunked[ok], whole[ok], tolerance = 1e-7)
})

test_that("warp propagates integer nodata correctly", {
  skip_if_not_installed("terra")
  f <- fixture_i16_nodata()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(59L, 41L))

  a <- lazy_source(f)                    # f32 + NaN (D8)
  got <- collect(align(a, target, resampling = "nearest"))
  want <- as.matrix(
    terra::project(terra::rast(f),
                   terra::rast(nrows = 41, ncols = 59,
                               extent = terra::ext(b[c(1, 3, 2, 4)]),
                               crs = "EPSG:4326"),
                   method = "near"), wide = TRUE)

  expect_gt(mean(is.nan(got) == is.na(want)), 0.98)
  ok <- !is.nan(got) & !is.na(want)
  expect_gt(mean(got[ok] == want[ok]), 0.98)
})

test_that("warping a computed raster raises the structured error", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  m <- a * 2
  expect_error(collect(align(m, .warp_target()), plan_only = TRUE),
               class = "garry_warp_unsupported_error")
})

test_that("align to the identical grid pastes: no WarpNode, no warp
           stage, bit-exact reads (gap 7)", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  a <- lazy_source(f)

  # no-op at the IR level (any resampling: nothing is resampled)
  same <- align(a, g, resampling = "bilinear")
  expect_identical(same@node_id, a@node_id)
  expect_identical(align(a, a)@node_id, a@node_id)

  p <- collect(same + 0, plan_only = TRUE)
  expect_false(any(vapply(p@stages, function(s) s@kind == "warp",
                          logical(1))))
  expect_identical(collect(same),
                   gdal_read_window(f, 1L, 0L, 0L,
                                    unname(g@dims[["x"]]),
                                    unname(g@dims[["y"]])))

  # a half-pixel-shifted grid is NOT a paste: it must warp
  g2 <- grid_spec(g@crs,
                  extent = g@extent + g@transform[[2L]] / 2,
                  dims = unname(g@dims[c("x", "y")]),
                  dtype = g@dtype)
  shifted <- align(a, g2, resampling = "nearest")
  expect_false(identical(shifted@node_id, a@node_id))
  p2 <- collect(shifted, plan_only = TRUE)
  expect_true(any(vapply(p2@stages, function(s) s@kind == "warp",
                         logical(1))))
})
