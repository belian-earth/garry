# align -> compute pipelines end to end, including focal-after-warp
# (allowed by D11: warp stages satisfy halos like sources do).

skip_if_not_installed("anvl")

test_that("align -> map matches reference", {
  skip_if_not_installed("terra")
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(70L, 50L))

  a <- lazy_source(f)
  got <- collect(align(a, target) * 2 + 1)

  r <- terra::rast(f)
  tmpl <- terra::rast(nrows = 50, ncols = 70,
                      extent = terra::ext(b[c(1, 3, 2, 4)]),
                      crs = "EPSG:4326")
  want <- as.matrix(terra::project(r, tmpl, method = "bilinear") * 2 + 1,
                    wide = TRUE)
  ok <- !is.nan(got) & !is.na(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("focal after warp is chunk-invariant (halo on warp stage)", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(70L, 50L))

  a <- lazy_source(f)
  expr <- focal(align(a, target),
                fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  p <- collect(expr, plan_only = TRUE)
  warp_stage <- Filter(function(s) s@kind == "warp", p@stages)[[1L]]
  expect_identical(warp_stage@halo, 1L)   # halo satisfied by the VRT read

  old <- options(garry.chunk_target_px = 1e6)
  whole <- collect(expr)
  options(garry.chunk_target_px = 19 * 17)
  chunked <- collect(expr)
  options(old)
  expect_identical(is.nan(chunked), is.nan(whole))
  ok <- !is.nan(whole)
  expect_equal(chunked[ok], whole[ok], tolerance = 1e-6)
})
