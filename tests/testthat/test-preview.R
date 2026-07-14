# preview(): the matrix-native render engine (.plot_array) plus the front doors
# (array / file path / lazy object). Rendering gates draw to a throwaway PDF
# device and assert no error; the colour/stretch helpers are checked exactly.

test_that("stretch range: NULL is min/max, percentile clips inward", {
  v <- c(1, 2, 3, NA, 100)
  expect_equal(.pv_range(v, NULL), c(1, 100))
  r <- .pv_range(v, c(2, 98))
  expect_gte(r[[1L]], 1); expect_lt(r[[2L]], 100)     # inside the raw range
})

test_that("normalize clamps to [0,1] and preserves NA", {
  expect_equal(.pv_normalize(c(-5, 0, 5, 10, NA), c(0, 10)),
               c(0, 0, 0.5, 1, NA))
})

test_that("discrete detection: few levels categorical, many continuous", {
  expect_equal(.pv_discrete(c(3, 1, 2, 2, 3)), c(1, 2, 3))
  expect_null(.pv_discrete(1:50))
})

test_that("ramp maps [0,1] to hex; non-finite to NA (transparent)", {
  cols <- .pv_ramp(c("black", "white"))(c(0, 1, NA, NaN, Inf))
  expect_identical(cols[1:2], c("#000000", "#FFFFFF"))
  expect_true(all(is.na(cols[3:5])))
})

test_that(".plot_array renders single / RGB / discrete without error", {
  g <- grid_spec("EPSG:32632", extent = c(0, 0, 60, 40), dims = c(60, 40),
                 dtype = "f32")
  tf <- tempfile(fileext = ".pdf"); grDevices::pdf(tf)
  on.exit({ grDevices::dev.off(); unlink(tf) })
  expect_error(.plot_array(matrix(1:2400 + 0, 40, 60), grid = g, legend = TRUE), NA)
  expect_error(.plot_array(array(seq_len(40 * 60 * 3) + 0, c(40, 60, 3)),
                           grid = g, bands = 1:3), NA)
  expect_error(.plot_array(matrix(sample(1:4, 2400, TRUE), 40, 60), grid = g,
                           legend = TRUE), NA)
  # no grid -> pixel axes still work
  expect_error(.plot_array(matrix(1:2400 + 0, 40, 60)), NA)
})

test_that(".plot_array rejects a band count other than 1 or 3", {
  tf <- tempfile(fileext = ".pdf"); grDevices::pdf(tf)
  on.exit({ grDevices::dev.off(); unlink(tf) })
  expect_error(.plot_array(array(0, c(4, 4, 4)), bands = 1:2), "1 or 3")
})

test_that("preview() dispatches over array, path, and lazy objects", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  ds <- as_dataset(list(a = list(s()), b = list(s() * 2), c = list(s() * 3)))

  tf <- tempfile(fileext = ".pdf"); grDevices::pdf(tf)
  on.exit({ grDevices::dev.off(); unlink(tf) })

  arr <- collect(ds)
  expect_error(preview(arr), NA)                       # collected array
  expect_identical(preview(ds, bands = c("a", "b", "c")), ds)  # names -> RGB, returns x

  out <- tempfile(fileext = ".tif"); collect(ds, path = out, nodata = -9999)
  expect_error(preview(out, bands = 1), NA)            # file path front door
})

test_that("preview() rejects unsupported input", {
  expect_error(preview(list(1, 2, 3)), "LazyRaster")
})

# A grid-pinned LazyRaster: a one-tile local GTI over the gradient fixture, so
# the read warps (and decimates) on demand -- exercisable offline.
.pinned_lr <- function() {
  f <- fixture_gradient_f32()
  ext <- c(500000, 4599600, 500600, 4600000)          # the fixture's extent
  grid <- grid_spec("EPSG:32632", extent = ext, dims = c(60, 40), dtype = "f32")
  gti <- tempfile(fileext = ".gti.fgb")
  gti_index_create(
    data.frame(location = f, xmin = ext[1], ymin = ext[2],
               xmax = ext[3], ymax = ext[4]),
    gti, crs = "EPSG:32632")
  list(lr = lazy_source(paste0("GTI:", gti), open_options = gti_open_options(grid),
                        grid = grid, block_dim = c(60L, 40L)),
       grid = grid)
}

test_that(".coarsen_grid rescales x/y, preserves extent and dtype", {
  g <- grid_spec("EPSG:32632", extent = c(0, 0, 1200, 800), dims = c(120, 80),
                 dtype = "f32")
  cg <- .coarsen_grid(g, 4)
  expect_equal(unname(cg@dims[c("x", "y")]), c(30L, 20L))
  expect_equal(cg@extent, g@extent)                    # same footprint
  expect_equal(cg@transform[[2L]], 40)                 # res * 4
  expect_identical(cg@dtype, "f32")
})

test_that(".coarsen_open_options swaps RESX/RESY, keeps the rest", {
  g  <- grid_spec("EPSG:32632", extent = c(0, 0, 1200, 800), dims = c(120, 80),
                  dtype = "f32")
  cg <- .coarsen_grid(g, 4)
  coo <- .coarsen_open_options(gti_open_options(g, filter = "slice=x"), cg)
  expect_true(any(grepl("^RESX=40", coo)))
  expect_true(any(grepl("FILTER=slice=x", coo)))       # non-grid options kept
  expect_length(grep("^RESX=", coo), 1L)               # not duplicated
})

test_that(".preview_coarsen re-plans grid-pinned sources; NULL otherwise", {
  # Non-pinned (plain file source) -> NULL so the caller falls back.
  expect_null(.preview_coarsen(lazy_source(fixture_gradient_f32()) * 2, 20))

  p <- .pinned_lr()
  coarse <- .preview_coarsen(p$lr, 20)
  expect_true(S7::S7_inherits(coarse, LazyRaster))
  expect_lte(max(coarse@grid@dims[c("x", "y")]), 20L)  # long axis <= target
  # the coarse source fetches at coarse resolution (RESX rewritten)
  src <- graph_get(coarse@graph, .reachable(coarse@graph, coarse@node_id)[[1L]])
  expect_true(any(grepl("^RESX=", src@open_options)) &&
              !any(grepl("^RESX=10\\b", src@open_options)))
})

test_that("coarse preview reads COG overviews, even for a derived band", {
  skip_if_not_installed("anvl")
  # A checkerboard: native pixels are 0/1; the AVERAGE overview is ~0.5. A coarse
  # read that uses the overview is uniform (sd ~ 0); native decimation scatters.
  n <- 256
  cb <- outer(1:n, 1:n, function(r, c) (r + c) %% 2)
  cog <- tempfile(fileext = ".tif")
  ds <- gdalraster::create("GTiff", cog, n, n, 1, "Float32", return_obj = TRUE,
    options = c("TILED=YES", "BLOCKXSIZE=64", "BLOCKYSIZE=64"))
  ds$setGeoTransform(c(0, 1, 0, n, 0, -1))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  ds$write(1, 0, 0, n, n, as.numeric(t(cb))); ds$close()
  d2 <- new(gdalraster::GDALRaster, cog, read_only = FALSE)
  d2$buildOverviews("AVERAGE", levels = c(2, 4, 8), bands = 1); d2$close()

  gti <- tempfile(fileext = ".gti.fgb")
  gti_index_create(data.frame(location = cog, xmin = 0, ymin = 0,
                              xmax = n, ymax = n), gti, crs = "EPSG:32632")
  grid <- grid_spec("EPSG:32632", extent = c(0, 0, n, n), dims = c(n, n),
                    dtype = "f32")
  lr <- lazy_source(paste0("GTI:", gti), open_options = gti_open_options(grid),
                    grid = grid, block_dim = c(n, n))
  deriv <- (lr - lr * 0.5) / (lr + lr * 0.5 + 1)   # MapNode top: misses fast path

  arr <- .pv_collect(deriv, 32)$arr
  expect_lte(max(dim(arr)), 32L)
  expect_lt(sd(as.numeric(arr)), 0.02)             # overview (uniform), not native
})

test_that("preview() coarse-collects a grid-pinned lazy raster", {
  skip_if_not_installed("anvl")
  p <- .pinned_lr()
  # the coarse pipeline actually executes at reduced res
  arr <- collect(.preview_coarsen(p$lr, 20))
  expect_lte(max(dim(arr)), 20L)
  expect_true(all(is.finite(arr)))

  tf <- tempfile(fileext = ".pdf"); grDevices::pdf(tf)
  on.exit({ grDevices::dev.off(); unlink(tf) })
  expect_error(preview(p$lr, max_px = 20), NA)
})
