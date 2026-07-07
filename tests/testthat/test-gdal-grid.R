# Phase 4a gate: gdal_grid_spec metadata vs terra as an independent
# reference, and lazy_source wiring (block_dim, nodata promotion).

test_that("gdal_grid_spec matches terra metadata (f32 fixture)", {
  skip_if_not_installed("terra")
  f <- fixture_gradient_f32()
  meta <- gdal_grid_spec(f)
  r <- terra::rast(f)

  g <- meta$grid
  e <- as.vector(terra::ext(r))   # terra order: xmin, xmax, ymin, ymax
  expect_equal(unname(c(xmin(g), xmax(g), ymin(g), ymax(g))),
               unname(e[c("xmin", "xmax", "ymin", "ymax")]))
  expect_equal(unname(g@dims[c("x", "y")]),
               c(terra::ncol(r), terra::nrow(r)))
  expect_equal(res(g), terra::res(r))
  expect_true(crs_equal(g@crs, terra::crs(r)))
  expect_identical(g@dtype, "f32")
  expect_length(meta$nodata, 0L)
})

test_that("gdal_grid_spec reads dtype, nodata, and block of i16 fixture", {
  f <- fixture_i16_nodata()
  meta <- gdal_grid_spec(f)
  expect_identical(meta$grid@dtype, "i16")
  expect_identical(meta$nodata, -9999)
  expect_identical(meta$block_dim, c(16L, 16L))
})

test_that("lazy_source promotes i16+nodata to f32 and stores block_dim", {
  f <- fixture_i16_nodata()
  lr <- lazy_source(f)
  expect_identical(lr@grid@dtype, "f32")
  node <- graph_get(lr@graph, lr@node_id)
  expect_identical(node@nodata, -9999)
  expect_identical(node@block_dim, c(16L, 16L))

  # f64 fixture keeps its dtype, no nodata.
  lr2 <- lazy_source(fixture_3857_f64())
  expect_identical(lr2@grid@dtype, "f64")
  expect_true(crs_equal(lr2@grid@crs, "EPSG:3857"))
})

test_that("chunking snaps to the native block size of a real source", {
  f <- fixture_i16_nodata()
  lr <- lazy_source(f)
  old <- options(garry.chunk_target_px = 300)   # side 17 -> snaps to 32
  on.exit(options(old))
  p <- collect(lr + 0L, plan_only = TRUE)
  compute <- Find(function(s) s@kind == "compute", p@stages)
  expect_identical(compute@chunks@chunk_dim, c(32L, 32L))
  # Halo-free source reads are coarser: an integer multiple of the
  # compute tiling (read-granularity decoupling).
  src <- p@stages[[1L]]
  expect_identical(src@chunks@block_dim, c(16L, 16L))
  expect_identical(unname(src@chunks@chunk_dim %% compute@chunks@chunk_dim),
                   c(0L, 0L))
  expect_true(all(src@chunks@chunk_dim >= compute@chunks@chunk_dim))
})
