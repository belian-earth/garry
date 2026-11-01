# align -> compute pipelines end to end, including focal-after-warp
# (allowed by D11: warp stages satisfy halos like sources do).


test_that("align -> map matches reference", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(70L, 50L))

  a <- lazy_source(f)
  got <- collect(align_to(a, target, resampling = "bilinear") * 2 + 1)

  want <- .geo_oracle(f, target, "bilinear") * 2 + 1
  ok <- !is.nan(got) & !is.nan(want)
  expect_gt(mean(ok), 0.5)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("focal after warp is chunk-invariant (halo on warp stage)", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(70L, 50L))

  a <- lazy_source(f)
  expr <- focal_map(align_to(a, target),
                fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)

  p <- collect(expr, plan_only = TRUE)
  warp_stage <- Filter(function(s) s@kind == "warp", p@stages)[[1L]]
  expect_identical(warp_stage@halo, 1L)   # halo satisfied by the VRT read

  whole <- .with_chunk_px(1e6, collect(expr))
  chunked <- .with_chunk_px(19 * 17, collect(expr))
  expect_identical(is.nan(chunked), is.nan(whole))
  ok <- !is.nan(whole)
  expect_gt(mean(ok), 0.5)
  expect_equal(chunked[ok], whole[ok], tolerance = 1e-6)
})
