# kalman_llt() vs KFAS: the scan-node Kalman smoother must reproduce
# KFAS's KFS() (exact diffuse init, local linear trend, smoothing = "state")
# to tight tolerance on the smoothed level mean and sd, including gappy
# and minimal series. KFAS's answers are saved in fixtures/kfas/ by
# tools/kfas_make_fixture.R. The pure-R (untraced) body is the referee; the
# traced (PJRT) body and the full scan_over plan must match it.

.kfas <- oracle_cases("kfas", "kalman-llt")

# hutan-like hyperparameters used throughout: sigma_lvl 1, sigma_slp 0.1,
# sigma_obs 2  =>  q_lvl 1, q_slp 0.01, H 4.
.k_body <- function(output, ...) {
  kalman_llt(sigma_lvl = 1, sigma_slp = 0.1, sigma_obs = 2,
             output = output, dtype = "f64", ...)
}

.k_series <- function(T_ = 15) {
  cumsum(cumsum(stats::rnorm(T_, 0, 0.1)) + stats::rnorm(T_, 0, 1)) +
    stats::rnorm(T_, 0, 2)
}

test_that("smoothed mean and sd match KFAS on dense and gappy series", {
  bm <- .k_body("mean")
  bs <- .k_body("sd")
  for (nm in names(.kfas$base)) {
    ref <- .kfas$base[[nm]]
    cube <- array(ref$y, c(length(ref$y), 1, 1))
    gm <- as.numeric(bm(list(cube), 1L))
    gs <- as.numeric(bs(list(cube), 1L))
    expect_lt(max(abs(gm - ref$mean) / pmax(abs(ref$mean), 1)), 1e-5,
              label = paste0(nm, ": smoothed mean rel diff"))
    expect_lt(max(abs(gs - ref$sd) / pmax(ref$sd, 1e-9)), 1e-5,
              label = paste0(nm, ": smoothed sd rel diff"))
  }
})

test_that("per-year relative observation variance matches KFAS", {
  ref <- .kfas$relvar
  cube <- array(ref$y, c(15, 1, 1))
  rcube <- array(ref$r, c(15, 1, 1))
  gm <- as.numeric(.k_body("mean")(list(cube, rcube), 1L))
  gs <- as.numeric(.k_body("sd")(list(cube, rcube), 1L))
  expect_lt(max(abs(gm - ref$mean) / pmax(abs(ref$mean), 1)), 1e-5)
  expect_lt(max(abs(gs - ref$sd) / pmax(ref$sd, 1e-9)), 1e-5)
})

test_that("pixels with < 3 valid observations return all-NaN", {
  set.seed(4)
  y2 <- .k_series(); y2[-c(1, 15)] <- NaN      # 2 valid
  y0 <- rep(NaN, 15)                           # 0 valid
  cube <- array(NA_real_, c(15, 2, 1))         # (t, y, x)
  cube[, 1, 1] <- y2
  cube[, 2, 1] <- y0
  gm <- .k_body("mean")(list(cube), 1L)
  gs <- .k_body("sd")(list(cube), 1L)
  expect_true(all(is.na(gm)))
  expect_true(all(is.na(gs)))
})

test_that("the batched body advances every pixel independently", {
  # five 15-year series and a sixth pixel with too few observations, filling
  # the (y, x) plane column by column
  base <- Filter(function(cs) length(cs$y) == 15L, .kfas$base)
  sparse <- rep(NaN, 15L)
  sparse[c(1L, 15L)] <- 1
  cube <- array(c(unlist(lapply(base, `[[`, "y")), sparse), c(15L, 3L, 2L))
  gm <- .k_body("mean")(list(cube), 1L)
  for (i in seq_along(base)) {
    px <- arrayInd(i, c(3L, 2L))
    ref <- base[[i]]
    expect_lt(max(abs(gm[, px[[1L]], px[[2L]]] - ref$mean) / pmax(abs(ref$mean), 1)),
              1e-5, label = names(base)[[i]])
  }
  expect_true(all(is.na(gm[, 3L, 2L])))
})

test_that("traced (PJRT) body matches the untraced oracle", {
  set.seed(6)
  cube <- array(.k_series(15 * 4 * 3), c(15, 4, 3))
  cube[sample(length(cube), 30)] <- NaN
  for (output in c("mean", "sd", "fmean", "fsd")) {
    body <- .k_body(output)
    jf <- g_jit(function(x) body(list(x), 1L))
    traced <- g_download(jf(g_upload(cube, "f32")))
    untraced <- body(list(cube), 1L)
    expect_identical(is.na(traced), is.na(untraced))
    # f32 input quantisation bounds the gap, not the f64 recursion
    expect_lt(max(abs(traced - untraced), na.rm = TRUE), 1e-4)
  }
})

test_that("kalman_smooth() through a full scan_over plan matches the referee", {
  set.seed(7)

  # 4-slice Float32 stack with NaN gaps, written to disk
  ny <- 20L; nx <- 30L; T_ <- 4L
  vals <- array(.k_series(T_ * ny * nx), c(T_, ny, nx))
  vals[sample(length(vals), 120)] <- NaN
  paths <- vapply(seq_len(T_), function(t) {
    f <- file.path(tempdir(), sprintf("garry-kalman-%d.tif", t))
    ds <- gdalraster::create("GTiff", f, nx, ny, 1, "Float32",
                             return_obj = TRUE)
    ds$setGeoTransform(c(500000, 10, 0, 4600000, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
    ds$write(1, 0, 0, nx, ny, as.numeric(t(vals[t, , ])))
    ds$close()
    f
  }, character(1))

  g <- graph_new()
  stk <- lazy_stack(lapply(paths, function(p) lazy_source(p, graph = g)),
                    along = "t")
  sm <- kalman_smooth(stk, sigma_lvl = 1, sigma_slp = 0.1, sigma_obs = 2)
  got_mean <- execute_plan(plan_lazy(sm$mean))
  got_sd <- execute_plan(plan_lazy(sm$sd))

  # referee: the untraced f64 body on the same values (f32-quantised)
  ref_m <- .k_body("mean")(list(array(vals, c(T_, ny, nx))), 1L)
  ref_s <- .k_body("sd")(list(array(vals, c(T_, ny, nx))), 1L)
  expect_identical(is.na(got_mean), is.na(ref_m))
  expect_lt(max(abs(got_mean - ref_m), na.rm = TRUE), 1e-3)  # f32 IO + output
  expect_lt(max(abs(got_sd - ref_s), na.rm = TRUE), 1e-3)
})

test_that("kalman_llt validates its arguments", {
  expect_error(kalman_llt(0, 0.1, 2), "finite positive")
  expect_error(kalman_llt(1, 0.1, 2, output = "variance"), "arg")
  expect_error(kalman_llt(c(1, 2), 0.1, 2), "finite positive")
  expect_error(kalman_llt(1, 0.1, 2, robust_iters = -1L), "robust_iters")
  expect_error(kalman_llt(1, 0.1, 2, robust_iters = 1.5), "robust_iters")
  expect_error(kalman_llt(1, 0.1, 2, robust_iters = NA), "robust_iters")
  expect_error(kalman_llt(1, 0.1, 2, robust_threshold = Inf), "robust_threshold")
  expect_error(kalman_llt(1, 0.1, 2, robust_inflation = 0), "robust_inflation")
  expect_error(kalman_llt(1, 0.1, 2, dtype = "f128"), "dtype")
  body <- kalman_llt(1, 0.1, 2, dtype = "f64")
  cube <- array(stats::rnorm(12), c(4, 3, 1))
  expect_error(body(list(cube), 2L), "margin")
})

# -- robust reweighting (phase 4) ----------------------------------------------

test_that("robust reweighting matches hutan's loop around KFAS", {
  bm <- .k_body("mean", robust_iters = 2L)
  bs <- .k_body("sd", robust_iters = 2L)
  for (nm in names(.kfas$robust)) {
    ref <- .kfas$robust[[nm]]
    cube <- array(ref$y, c(length(ref$y), 1, 1))
    gm <- as.numeric(bm(list(cube), 1L))
    gs <- as.numeric(bs(list(cube), 1L))
    expect_lt(max(abs(gm - ref$mean) / pmax(abs(ref$mean), 1)), 1e-5,
              label = paste0(nm, ": robust mean rel diff"))
    expect_lt(max(abs(gs - ref$sd) / pmax(ref$sd, 1e-9)), 1e-5,
              label = paste0(nm, ": robust sd rel diff"))
  }
  # sanity: the loop actually fired, on the break series alone
  expect_identical(
    lapply(.kfas$robust, function(r) r$q_years),
    list(onebreak = 8L, twobreak = c(5L, 11L), breakgap = 9:10, smooth = integer(0))
  )
  y <- .kfas$robust$onebreak$y
  plain <- as.numeric(.k_body("mean")(list(array(y, c(15, 1, 1))), 1L))
  robust <- as.numeric(bm(list(array(y, c(15, 1, 1))), 1L))
  expect_gt(max(abs(plain - robust)), 0.1)
})

test_that("robust reweighting is per pixel in a batched cube", {
  refs <- .kfas$robust[c("onebreak", "smooth")]
  cube <- array(NA_real_, c(15, 2, 1))
  cube[, 1, 1] <- refs$onebreak$y
  cube[, 2, 1] <- refs$smooth$y
  gm <- .k_body("mean", robust_iters = 2L)(list(cube), 1L)
  for (j in 1:2) {
    ref <- refs[[j]]
    expect_lt(max(abs(gm[, j, 1] - ref$mean) / pmax(abs(ref$mean), 1)),
              1e-5, label = paste("pixel", j))
  }
})

test_that("robust traced (PJRT) body matches the untraced oracle", {
  set.seed(10)
  cube <- array(.k_series(15 * 4 * 3), c(15, 4, 3))
  cube[8:15, 2, 2] <- cube[8:15, 2, 2] + 25       # one break pixel
  cube[sample(length(cube), 20)] <- NaN
  body <- .k_body("mean", robust_iters = 2L)
  jf <- g_jit(function(x) body(list(x), 1L))
  traced <- g_download(jf(g_upload(cube, "f32")))
  untraced <- body(list(cube), 1L)
  expect_identical(is.na(traced), is.na(untraced))
  expect_lt(max(abs(traced - untraced), na.rm = TRUE), 1e-3)
})

test_that("mean+sd collect as ONE multi-sink plan, scans sharing a stage", {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function(k) lazy_source(f, graph = g) * k
  stk <- lazy_stack(list(a = s(1), b = s(2), c = s(3), d = s(4)),
                    along = "t")
  sm <- kalman_smooth(stk, sigma_lvl = 1, sigma_slp = 0.1, sigma_obs = 2)

  # sibling scans share one compute stage (multi-export-collect.md s5):
  # the forward filter dedupes inside one kernel (measured 1.59x for
  # the pair vs 2x as separate stages/collects)
  p <- plan_lazy(sm)
  scan_stages <- Filter(function(st) any(vapply(st@members, function(id)
    S7::S7_inherits(graph_get(p@graph, id), garry::ScanNode), TRUE)),
    p@stages)
  expect_length(scan_stages, 1L)
  expect_length(p@sinks, 2L)

  # one collect returns both, equal to the separate collects
  both <- collect(sm, distributed = FALSE)
  expect_identical(names(both), c("mean", "sd"))
  expect_equal(both$mean, collect(sm$mean, distributed = FALSE),
               tolerance = 1e-6)
  expect_equal(both$sd, collect(sm$sd, distributed = FALSE),
               tolerance = 1e-6)
})

test_that("filtered mean and sd match KFAS; the revision variance is fsd^2 - sd^2", {
  for (nm in names(.kfas$filtered)) {
    ref <- .kfas$filtered[[nm]]
    y <- ref$y
    cube <- array(y, c(length(y), 1, 1))
    fm <- as.numeric(.k_body("fmean")(list(cube), 1L))
    fs <- as.numeric(.k_body("fsd")(list(cube), 1L))
    # the local linear trend has two diffuse states: until two years are
    # observed KFAS (exact diffuse) and garry (kappa) differ by design
    ok <- cumsum(!is.na(y)) >= 2L
    expect_lt(max(abs(fm[ok] - ref$fmean[ok]) / pmax(abs(ref$fmean[ok]), 1)), 1e-5,
              label = paste0(nm, ": filtered mean rel diff"))
    expect_lt(max(abs(fs[ok] - ref$fsd[ok]) / pmax(ref$fsd[ok], 1e-9)), 1e-5,
              label = paste0(nm, ": filtered sd rel diff"))
    # the last year is both filtered and smoothed
    sm <- as.numeric(.k_body("mean")(list(cube), 1L))
    ss <- as.numeric(.k_body("sd")(list(cube), 1L))
    last <- max(which(!is.na(fm)))
    expect_equal(fm[last], sm[last], tolerance = 1e-10)
    # smoothing never adds variance: fsd >= sd wherever both are defined
    expect_true(all(fs[ok] >= ss[ok] - 1e-9))
  }
})


test_that("innov matches KFAS's standardised innovations after the diffuse phase", {
  ref <- .kfas$innov
  y <- ref$y
  cube <- array(y, c(length(y), 1, 1))
  z <- as.numeric(.k_body("innov")(list(cube), 1L))
  ok <- cumsum(!is.na(y)) > 2L & !is.na(y)
  expect_lt(max(abs(z[ok] - ref$innov[ok])), 1e-5)
  expect_equal(z[7], 0)                                    # a missing year: no surprise
})

test_that("a regime boundary splits the series into two independent smoothers", {
  y <- .kfas$regime$y; T_ <- length(y); b <- .kfas$regime$b
  cube <- array(y, c(T_, 1, 1)); r <- array(1, c(T_, 1, 1))
  bd <- array(0, c(T_, 1, 1)); bd[b, , ] <- 1
  body <- function(o) kalman_llt(sigma_lvl = 0.1, sigma_slp = 0.05, sigma_obs = 0.5, output = o, dtype = "f64")
  got <- function(o) as.numeric(body(o)(list(cube, r, bd), 1L))
  plain <- function(o) as.numeric(body(o)(list(cube, r), 1L))
  # before the boundary: the smoother of y[1:(b-1)] alone (no observation
  # from the boundary on reaches back)
  ref_pre <- .kfas$regime$pre
  expect_lt(max(abs(got("mean")[1:(b - 1L)] - ref_pre$mean) / pmax(abs(ref_pre$mean), 1)), 1e-5)
  expect_lt(max(abs(got("sd")[1:(b - 1L)] - ref_pre$sd) / pmax(ref_pre$sd, 1e-9)), 1e-5)
  # from the boundary: the smoother of y[b:T] alone, from the diffuse start
  ref_post <- .kfas$regime$post
  ok <- which(cumsum(!is.na(y[b:T_])) >= 2L)              # KFAS's exact-diffuse years differ by design
  expect_lt(max(abs(got("mean")[b:T_][ok] - ref_post$mean[ok]) / pmax(abs(ref_post$mean[ok]), 1)), 1e-4)
  # and the plain smoother leaks the step into the years before it
  expect_gt(plain("mean")[b - 1L] - got("mean")[b - 1L], 0.5)
  # the forward filter restarts too: the first post-boundary filtered value is that year's observation
  expect_lt(abs(got("fmean")[b] - y[b]), 1e-3)
})

test_that("boundaries: traced (PJRT) body matches the untraced oracle", {
  set.seed(16)
  cube <- array(.k_series(15 * 4 * 3), c(15, 4, 3)); cube[sample(length(cube), 20)] <- NaN
  r <- array(1, dim(cube)); bd <- array(0, dim(cube)); bd[9, , ] <- 1; bd[12, 2, ] <- 1
  for (output in c("mean", "sd", "fmean", "innov")) {
    body <- .k_body(output)
    jf <- g_jit(function(x, r, b) body(list(x, r, b), 1L))
    traced <- g_download(jf(g_upload(cube, "f32"), g_upload(r, "f32"), g_upload(bd, "f32")))
    untraced <- body(list(cube, r, bd), 1L)
    expect_identical(is.na(traced), is.na(untraced))
    expect_lt(max(abs(traced - untraced), na.rm = TRUE), 1e-3)
  }
})

test_that("kalman_smooth checks its dataset arguments", {
  f <- fixture_gradient_f32()
  g <- graph_new()
  s <- function(k) lazy_source(f, graph = g) * k
  ds <- as_dataset(list(
    a = list(t1 = s(1), t2 = s(2), t3 = s(3)),
    b = list(t1 = s(4), t2 = s(5), t3 = s(6))
  ))
  expect_error(
    kalman_smooth(ds, 1, 0.1, obs_var = ds$a),
    "need a <garry::LazyRaster>|LazyRaster"
  )
  expect_error(kalman_smooth(ds$a, 1, 0.1, bands = "a"), "applies to a")
  sm <- kalman_smooth(ds, 1, 0.1, bands = "a")
  expect_true(S7::S7_inherits(sm$mean, LazyDataset))
})

test_that("a regime with no observation is NaN, not the previous regime's trend", {
  set.seed(17); T_ <- 12L; b <- 8L
  y <- 3 + stats::rnorm(T_, 0, 0.5)
  y[b:T_] <- NaN # the second regime is never observed
  y[5] <- NaN # a gap inside the first regime
  cube <- array(y, c(T_, 1, 1)); r <- array(1, c(T_, 1, 1))
  bd <- array(0, c(T_, 1, 1)); bd[b, , ] <- 1
  body <- function(o) kalman_llt(sigma_lvl = 0.1, sigma_slp = 0.05, sigma_obs = 0.5, output = o, dtype = "f64")
  got <- function(o) as.numeric(body(o)(list(cube, r, bd), 1L))
  for (o in c("mean", "sd", "fmean", "fsd")) {
    v <- got(o)
    expect_true(all(is.nan(v[b:T_])), info = o)
    expect_false(anyNA(v[1:(b - 1L)]), info = o) # a gap is still estimated
  }
  # traced agrees
  traced <- garry:::g_jit(function(inputs) list(out = body("mean")(inputs, 1L)))
  tv <- as.numeric(g_download(traced(lapply(list(cube, r, bd), g_upload, dtype = "f64")))$out)
  expect_equal(is.nan(tv), is.nan(got("mean")))
})

test_that("a variance that broke stays NaN: it does not read as perfect certainty", {
  y <- c(1, 2, 3, 4, 5, 6)
  cube <- array(y, c(6, 1, 1))
  # a prior this wide overflows, so every covariance term is NaN
  testthat::local_mocked_bindings(.kalman_kappa = 1e308)
  body <- kalman_llt(1, 0.1, 2, output = "sd", dtype = "f64")
  expect_true(all(is.na(as.numeric(body(list(cube), 1L)))))
  jf <- g_jit(function(x) body(list(x), 1L))
  expect_true(all(is.nan(g_download(jf(g_upload(cube, "f64"))))))
  # a variance a hair below zero is rounding, and still floors at zero
  expect_identical(as.numeric(garry:::.variance_sd(c(-1e-12, 0, 4))), c(0, 0, 2))
})
