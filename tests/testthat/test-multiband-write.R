# Multiband write sink: a band-stacked LazyRaster collects into one
# multi-band GTiff. One plan for all bands means one scheduler pass —
# the fix for per-band sequential collects in composite workloads.

skip_if_not_installed("anvl")

test_that("band stack writes a multiband GTiff, layer order preserved", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  stacked <- lazy_stack(list(a * 1, a * 2, a + 100), along = "band")
  expect_identical(unname(stacked@grid@dims[["band"]]), 3L)

  outfile <- tempfile(fileext = ".tif")
  collect(stacked, path = outfile)

  meta <- gdal_grid_spec(outfile)
  expect_true(grid_equal(meta$grid, gdal_grid_spec(f)$grid))
  m <- gdal_read_window(f, 1L, 0L, 0L, 60L, 40L)
  wants <- list(m, m * 2, m + 100)
  for (b in 1:3) {
    back <- gdal_read_window(outfile, b, 0L, 0L, 60L, 40L)
    expect_equal(back, wants[[b]], tolerance = 0)
  }
})

test_that("multiband write demotes NaN to the sentinel in every band", {
  f <- fixture_i16_nodata()                 # promotes to f32 with NaN
  a <- lazy_source(f)
  stacked <- lazy_stack(list(a, a * 2), along = "band")
  outfile <- tempfile(fileext = ".tif")
  collect(stacked, path = outfile, nodata = -9999)

  ds <- methods::new(gdalraster::GDALRaster, outfile)
  on.exit(ds$close(), add = TRUE)
  expect_identical(ds$getRasterCount(), 2L)
  expect_identical(ds$getNoDataValue(1L), -9999)
  expect_identical(ds$getNoDataValue(2L), -9999)

  want <- gdal_read_window(f, 1L, 0L, 0L, 70L, 50L,
                           nodata = gdal_grid_spec(f)$nodata)
  for (b in 1:2) {
    back <- gdal_read_window(outfile, b, 0L, 0L, 70L, 50L, nodata = -9999)
    expect_identical(is.nan(back), is.nan(want))
  }
})

test_that("band-stacked composites share sources and match per-band runs", {
  # The composite-benchmark shape in miniature: two "bands" masked by
  # ONE shared QA layer, each median-composited over t, stacked along
  # band, collected once. The shared QA source must dedup to a single
  # SourceNode in the merged graph (the Fmask-sharing property), and
  # each band of the file must equal its standalone single-band run.
  mk <- function(name, vals, dtype = "Float32") {
    fp <- file.path(tempdir(), sprintf("garry-mbw-%s.tif", name))
    ds <- gdalraster::create("GTiff", fp, 12, 9, 1, dtype,
                             return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 90, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    ds$write(1, 0, 0, 12, 9, as.numeric(vals))
    ds$close()
    fp
  }
  n <- 12 * 9
  f_b1 <- mk("b1", seq_len(n))
  f_b2 <- mk("b2", seq_len(n) * 10)
  f_qa <- mk("qa", rep(c(0, 2, 0), length.out = n), dtype = "Byte")

  composite_of <- function(band_path) {
    masked <- lapply(c(0, 100), function(off) {
      lazy_map(lazy_source(band_path) + off, lazy_source(f_qa),
               dtype = "f32", fn = function(x, q) {
                 bad <- g_bitand(g_cast(q, "i32"), 2L) > 0
                 g_ifelse(bad, NaN, x)
               })
    })
    reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
  }

  out <- lazy_stack(list(composite_of(f_b1), composite_of(f_b2)),
                    along = "band")
  sources <- Filter(function(i)
    S7::S7_inherits(graph_get(out@graph, i), SourceNode),
    graph_ids(out@graph))
  expect_length(sources, 3L)   # b1, b2, qa once — not qa per band

  outfile <- tempfile(fileext = ".tif")
  collect(out, path = outfile, nodata = -9999)

  for (b in 1:2) {
    solo <- collect(composite_of(list(f_b1, f_b2)[[b]]))
    back <- gdal_read_window(outfile, b, 0L, 0L, 12L, 9L,
                             nodata = -9999)
    expect_identical(is.nan(back), is.nan(solo))
    ok <- !is.nan(solo)
    expect_equal(back[ok], solo[ok], tolerance = 1e-5)
  }
})
