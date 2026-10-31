# Phase 4b gate: warp = lazy VRT, GDAL owns cross-CRS pixel math (D5).
# terra::project (also GDAL underneath) is the independent reference.
#
# Target grids use dims that do NOT align target pixel centres with
# source cell edges; nearest-neighbour comparisons still allow a <=2%
# disagreement for residual boundary ties (both engines are GDAL, but
# tie-breaking at exact cell boundaries is not contractual).


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
  got <- collect(align_to(a, target, resampling = "bilinear"))
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
  got <- collect(align_to(a, target, resampling = "nearest"))
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
  w <- align_to(a, .warp_target(), resampling = "bilinear")

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
  got <- collect(align_to(a, target, resampling = "nearest"))
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
  expect_error(collect(align_to(m, .warp_target()), plan_only = TRUE),
               class = "garry_warp_unsupported_error")
})

test_that("align to the identical grid pastes: no WarpNode, no warp
           stage, bit-exact reads (gap 7)", {
  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  a <- lazy_source(f)

  # no-op at the IR level (any resampling: nothing is resampled)
  same <- align_to(a, g, resampling = "bilinear")
  expect_identical(same@node_id, a@node_id)
  expect_identical(align_to(a, a)@node_id, a@node_id)

  p <- collect(same + 0, plan_only = TRUE)
  expect_false(any(vapply(p@stages, function(s) s@kind == "warp",
                          logical(1))))
  expect_equal(collect(same),
               gdal_read_window(f, 1L, 0L, 0L,
                                unname(g@dims[["x"]]),
                                unname(g@dims[["y"]])),
               ignore_attr = "gis")

  # a half-pixel-shifted grid is NOT a paste: it must warp
  g2 <- grid_spec(g@crs,
                  extent = g@extent + g@transform[[2L]] / 2,
                  dims = unname(g@dims[c("x", "y")]),
                  dtype = g@dtype)
  shifted <- align_to(a, g2, resampling = "nearest")
  expect_false(identical(shifted@node_id, a@node_id))
  p2 <- collect(shifted, plan_only = TRUE)
  expect_true(any(vapply(p2@stages, function(s) s@kind == "warp",
                         logical(1))))
})

test_that("a user-declared nodata stays out of warps and decimated reads", {
  f <- withr::local_tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", f, 4, 4, 1, "Float32", return_obj = TRUE)
  ds$setGeoTransform(c(0, 10, 0, 40, 0, -10))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
  v <- rep(100, 16)
  v[6] <- -9999 # the file declares no nodata
  ds$write(1, 0, 0, 4, 4, v)
  ds$close()
  x <- lazy_source(f, nodata = -9999)

  # cells outside the footprint are nodata, not 0
  big <- grid_spec("EPSG:3857", extent = c(-20, -20, 60, 60), dims = c(8L, 8L))
  a <- collect(align_to(x, big, resampling = "near"))
  expect_identical(sum(is.nan(a)), 49L) # 48 outside + the sentinel cell
  expect_true(all(a[!is.nan(a)] == 100))

  # the sentinel is never blended into resampled values
  fine <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(8L, 8L))
  b <- collect(align_to(x, fine, resampling = "bilinear"))
  expect_true(all(b[!is.nan(b)] == 100))
  coarse <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(2L, 2L))
  d <- collect(align_to(x, coarse, resampling = "average"))
  expect_true(all(d == 100))
})

test_that("align_to takes only the target's spatial geometry", {
  a <- lazy_source(fixture_gradient_f32())
  g <- a@grid
  coarse <- grid_spec(
    crs = grid_crs(g),
    extent = grid_bbox(g),
    dims = as.integer(c(g@dims[["x"]], g@dims[["y"]]) / 2)
  )
  stack <- lazy_stack(list(
    align_to(a, coarse, "average"),
    align_to(lazy_source(fixture_gradient_f32()), coarse, "near")
  ))
  w <- align_to(a, stack, resampling = "average")
  expect_identical(dim(w), dim(align_to(a, coarse, "average")))
  expect_null(time_labels(w))
  # a spatially identical target is a no-op whatever its outer axes
  same <- lazy_stack(list(a, a * 2))
  expect_identical(align_to(a, same)@node_id, a@node_id)
})

test_that("resampling names are checked when the node is built", {
  a <- lazy_source(fixture_gradient_f32())
  expect_error(align_to(a, a@grid, resampling = "bilnear"), "must be one of")
  expect_error(
    lazy_source(fixture_gradient_f32(), resampling = "bogus"),
    "must be one of"
  )
})

test_that("a band stack cannot be warped, before or after a collect collapses it", {
  mb <- fixture_multiband()
  g <- graph_new()
  st <- lazy_stack(list(
    a = lazy_source(mb$path, band = 1L, graph = g),
    b = lazy_source(mb$path, band = 2L, graph = g)
  ), along = "band")
  gr <- st@grid
  coarse <- grid_spec(
    crs = grid_crs(gr),
    extent = grid_bbox(gr),
    dims = as.integer(c(gr@dims[["x"]], gr@dims[["y"]]) / 2)
  )
  expect_error(collect(align_to(st, coarse), plan_only = TRUE),
               class = "garry_warp_unsupported_error")
  invisible(collect(st * 2)) # collapses the stack into a multi-band read
  expect_error(collect(align_to(st, coarse)),
               class = "garry_warp_unsupported_error")
})

test_that("align_to refuses a computed raster when it is built", {
  a <- lazy_source(fixture_gradient_f32())
  g <- a@grid
  coarse <- grid_spec(crs = grid_crs(g), extent = grid_bbox(g), dims = c(30L, 20L))
  expect_error(align_to(a * 2, coarse), class = "garry_warp_unsupported_error")
  x2 <- a * 2
  expect_identical(align_to(x2, x2)@node_id, x2@node_id) # same grid: a no-op
})

test_that("a warp of a source opened with options reads what they select", {
  gti <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(1000)))
  s1 <- .gg_slice(gti, "s1", graph_new())
  half <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400), dims = c(30L, 20L))
  got <- collect(align_to(s1, half), distributed = FALSE)
  expect_lt(max(got), 1000) # every cell of slice 2 is above 1000
})

test_that("a Zarr warp keeps its source's open options", {
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(4L, 4L))
  s <- SourceNode(id = 1L, parents = integer(0), grid = g,
                  path = "ZARR:\"/x.zarr\":/a", band = 1L, nodata = numeric(0),
                  block_dim = integer(0), open_options = "KEY=1")
  half <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(2L, 2L))
  w <- WarpNode(id = 2L, parents = 1L, grid = half, target_grid = half,
                resampling = "near")
  expect_identical(.warp_read_plan(w, s)$open_options, "KEY=1")
})

test_that("gdal_warp_window reads what the open options select", {
  gti <- .gg_gti(list(s1 = .gg_val(0), s2 = .gg_val(1000)))
  oo <- gti_open_options(.gg_grid, filter = "slice = 's1'", sort_field = "datetime")
  m <- gdal_warp_window(paste0("GTI:", gti), 1L, .gg_grid, 0L, 0L, 60L, 40L,
                        open_options = oo)
  expect_equal(m, .gg_val(0), ignore_attr = TRUE)
})

test_that("a warp of a GTI source keeps the source's own resampling", {
  gti <- .gg_gti(list(s1 = .gg_val(0)))
  x <- lazy_source(paste0("GTI:", gti), grid = .gg_grid, block_dim = c(60L, 40L),
                   open_options = gti_open_options(.gg_grid), resampling = "bilinear")
  half <- grid_spec("EPSG:3857", extent = c(0, 0, 600, 400), dims = c(30L, 20L))
  w <- align_to(x, half)
  rp <- .warp_read_plan(graph_get(w@graph, w@node_id), graph_get(w@graph, x@node_id))
  expect_true(any(grepl("bilinear.gti", readLines(rp$path), fixed = TRUE)))
})

test_that("an integer warp marks the cells past its footprint as missing", {
  big <- grid_spec("EPSG:3857", extent = c(-20, -20, 60, 60), dims = c(8L, 8L))
  ranges <- list(Byte = c(0, 255), Int8 = c(-128, 127), UInt16 = c(0, 65535),
                 Int16 = c(-32768, 32767), UInt32 = c(0, 4294967295),
                 Int32 = c(-2147483647, 2147483647))
  for (type in names(ranges)) {
    x <- align_to(lazy_source(fixture_tile(ranges[[type]], type)), big)
    m <- collect(x, distributed = FALSE)
    expect_identical(sum(is.nan(m)), 48L)
    # the ends of the band's range stay data
    expect_equal(sort(unique(as.numeric(m[3:6, 3:6]))), ranges[[type]])
    expect_error(collect(x + 1L, distributed = FALSE), class = "garry_nodata_error")
  }
  # an interpolated read still rounds to the band's type
  fine <- grid_spec("EPSG:3857", extent = c(0, 0, 40, 40), dims = c(8L, 8L))
  b <- collect(align_to(lazy_source(fixture_tile(1:16, "Byte")), fine, "bilinear"),
               distributed = FALSE)
  expect_true(all(b[!is.nan(b)] == round(b[!is.nan(b)])))
  expect_false(all(is.nan(b)))
})

test_that("a warp of an integer band keeps its values whatever marks the empty cells", {
  big <- grid_spec("EPSG:3857", extent = c(-20, -20, 60, 60), dims = c(8L, 8L))
  f <- fixture_tile(c(0, 3, 0, 3), "Byte")
  # a float copy of the warp, under a window
  m <- collect(focal_map(align_to(lazy_source(f), big), function(sh) sh[[5L]], 1L),
               distributed = FALSE)
  expect_true(all(m[3:6, c(3L, 5L)] == 0) && all(m[3:6, c(4L, 6L)] == 3))
  expect_identical(sum(is.nan(m)), 48L)
  # a sentinel the band cannot hold
  n <- collect(align_to(lazy_source(f, nodata = -1), big), distributed = FALSE)
  expect_true(all(n[3:6, c(3L, 5L)] == 0) && all(n[3:6, c(4L, 6L)] == 3))
  expect_identical(sum(is.nan(n)), 48L)
})

test_that("numbers reach GDAL with every digit", {
  v <- c(-999.99999, 0.123456789, -13627665.27123, 500010.123456, 1 / 3)
  expect_identical(as.numeric(.gdal_num(v)), v)
  # a grid past a double's 15th digit is its own grid
  g <- grid_spec("EPSG:3857", extent = c(1, 0, 41, 40), dims = c(4L, 4L))
  g2 <- grid_spec("EPSG:3857", extent = c(1 + 2e-15, 0, 41, 40), dims = c(4L, 4L))
  expect_false(identical(gdal_blank_vrt(g), gdal_blank_vrt(g2)))
  # a fractional sentinel still matches on a window warp
  sent <- 0.123456789
  f <- fixture_tile(c(sent, 1, 1, 1), "Float64")
  m <- gdal_warp_window(f, 1L, lazy_source(f)@grid, 0L, 0L, 4L, 4L, nodata = sent)
  expect_true(all(is.nan(m[, 1L])))
  expect_true(all(m[, 2:4] == 1))
})

test_that("open options apply to one plain source", {
  a <- fixture_tile(1)
  b <- fixture_tile(2, gt = c(40, 10, 0, 40, 0, -10))
  g <- grid_spec("EPSG:3857", extent = c(0, 0, 80, 40), dims = c(8L, 4L), dtype = "f32")
  expect_error(lazy_source(c(a, b), grid = g, open_options = "KEY=1"),
               class = "garry_source_error")
  expect_error(lazy_source(fixture_tile(1, "Byte"), decode = dequantize_aef,
                           open_options = "KEY=1"),
               class = "garry_source_error")
})

test_that("planning asks a warp's route without building its VRT", {
  x <- align_to(lazy_source(fixture_gradient_f32()), .warp_target(), resampling = "bilinear")
  n <- 0L
  real <- garry:::gdal_warp_vrt
  testthat::local_mocked_bindings(
    gdal_warp_vrt = function(...) {
      n <<- n + 1L
      real(...)
    },
    .package = "garry"
  )
  p <- plan_lazy(x)
  expect_identical(n, 0L)
  invisible(collect(x, distributed = FALSE))
  expect_gte(n, 1L)
})
