# bilateral_focal(): the edge-preserving 3x3 filter as a fused focal body.
# Gates: exact parity with rustyfilters' rf_bilateral (edge = "shrink",
# na_policy = "omit") on dense, NaN-holed, and edge pixels, untraced and
# through a full traced plan. rf_bilateral's answer is saved in
# fixtures/rustyfilters/ by tools/rustyfilters_make_fixture.R. .ref_bilateral()
# is in helper-kernels.R; test-route-kernels.R holds a plan to it on daemons.

test_that("bilateral_focal matches the reference and rf_bilateral (untraced)", {
  fx <- oracle_cases("rustyfilters", "bilateral")
  m <- fx$m
  sr <- fx$sigma_r; sd_ <- fx$sigma_d

  fn <- bilateral_focal(sigma_r = sr, sigma_d = sd_)
  # drive the body exactly as .eval_node does: NaN-padded shifts
  pad <- g_pad(m, 1L, NaN)
  shifts <- lapply(seq_len(9), function(k) {
    off <- expand.grid(dx = -1:1, dy = -1:1)
    g_shift_slice(pad, off$dy[k], off$dx[k], nrow(m), ncol(m), 1L)
  })
  got <- fn(shifts)
  want <- .ref_bilateral(m, sd_, sr)
  expect_equal(got, want, tolerance = 1e-12)
  expect_identical(is.na(got), is.na(want))
  expect_equal(as.numeric(got), as.numeric(fx$rf), tolerance = 1e-10)
  expect_equal(as.numeric(want), as.numeric(fx$rf), tolerance = 1e-10)
})

test_that("bilateral_focal through a traced plan matches the reference", {
  sr <- 3
  out <- execute_plan(plan_lazy(
    focal_map(.bilateral_source(), fn = bilateral_focal(sigma_r = sr), radius = 1L)))

  m <- .bilateral_plane()
  .expect_partial_nan(m)
  .expect_cells(unclass(out), .ref_bilateral(m, 1, sr), tolerance = 1e-4) # f32 kernel
})

test_that("bilateral_focal validates", {
  expect_error(bilateral_focal(0), "finite positive")
  expect_error(bilateral_focal(1, sigma_d = -1), "finite positive")
  fn <- bilateral_focal(1, radius = 2L)
  expect_error(fn(vector("list", 9L)), "same radius")
})

test_that("bilateral_focal: per-channel sigma_r filters a cube in one node", {
  set.seed(41)
  nch <- 3L; ny <- 24L; nx <- 20L
  cube <- .as_f32(array(rnorm(nch * ny * nx), c(nch, ny, nx)))
  sig <- c(0.6, 1.4, 2.5)
  g <- graph_new()
  slices <- lapply(1:nch, function(k) {
    f <- tempfile(fileext = ".tif")
    d <- gdalraster::create("GTiff", f, nx, ny, 1, "Float32", return_obj = TRUE)
    d$setGeoTransform(c(0, 30, 0, 4600000, 0, -30))
    d$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
    d$write(1, 0, 0, nx, ny, as.numeric(t(cube[k, , ])))
    d$close()
    lazy_source(f, graph = g)
  })
  stk <- lazy_stack(slices, along = "band")
  got <- execute_plan(plan_lazy(
    focal_map(stk, fn = bilateral_focal(sigma_r = sig), radius = 1L)))
  for (k in 1:nch) {
    expect_equal(got[k, , ], .ref_bilateral(cube[k, , ], 1, sig[k]), tolerance = 1e-5,
                 ignore_attr = TRUE, label = paste("channel", k))
  }
})

test_that("slimmed factory bodies keep their defining namespace as parent", {
  # bilateral_focal's closure lives in a garry exec env; slimming must
  # reparent onto the garry namespace (not globalenv) so unqualified g_*
  # calls resolve on daemons and in sessions where garry is not attached.
  fn <- bilateral_focal(1.5)
  slim <- garry:::.slim_fn(fn)
  env <- environment(slim)
  expect_true(isNamespace(parent.env(env)))
  expect_identical(environmentName(parent.env(env)), "garry")
  # captures copied into the slim env
  expect_true(length(ls(env)) > 0L)
})
