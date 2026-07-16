# kalman_llt() vs KFAS: the scan-node Kalman smoother must reproduce
# KFAS::KFS (exact diffuse init, local linear trend, smoothing = "state")
# to tight tolerance on the smoothed level mean and sd, including gappy
# and minimal series. The pure-R (untraced) body is the referee; the
# traced (PJRT) body and the full scan_over plan must match it.

kfas_llt <- function(y, q_lvl, q_slp, h) {
  # h: scalar or length(y) vector of observation variances.
  # SSMtrend must be resolvable UNQUALIFIED inside the formula (KFAS's
  # formula introspection breaks on namespace-qualified calls).
  SSMtrend <- KFAS::SSMtrend
  m <- KFAS::SSModel(
    y ~ SSMtrend(degree = 2, Q = list(matrix(q_lvl), matrix(q_slp))),
    H = array(h, c(1, 1, length(y)))
  )
  ks <- KFAS::KFS(m, smoothing = "state")
  list(mean = as.numeric(ks$alphahat[, "level"]),
       sd = sqrt(pmax(ks$V[1, 1, ], 0)))
}

# hutan-like hyperparameters used throughout: sigma_lvl 1, sigma_slp 0.1,
# sigma_obs 2  =>  q_lvl 1, q_slp 0.01, H 4.
.k_body <- function(output, ...) {
  kalman_llt(sigma_lvl = 1, sigma_slp = 0.1, sigma_obs = 2,
             output = output, out_dtype = "f64", ...)
}

.k_series <- function(T_ = 15) {
  cumsum(cumsum(stats::rnorm(T_, 0, 0.1)) + stats::rnorm(T_, 0, 1)) +
    stats::rnorm(T_, 0, 2)
}

test_that("smoothed mean and sd match KFAS on dense and gappy series", {
  skip_if_not_installed("KFAS")
  set.seed(2)
  cases <- list(
    dense    = .k_series(),
    leading  = { y <- .k_series(); y[1:4] <- NaN; y },
    trailing = { y <- .k_series(); y[12:15] <- NaN; y },
    midgap   = { y <- .k_series(); y[6:9] <- NaN; y },
    three    = { y <- .k_series(); y[-c(2, 9, 14)] <- NaN; y },
    short5   = .k_series(5)
  )
  bm <- .k_body("mean")
  bs <- .k_body("sd")
  for (nm in names(cases)) {
    y <- cases[[nm]]
    cube <- array(y, c(length(y), 1, 1))
    ref <- kfas_llt(y, q_lvl = 1, q_slp = 0.01, h = 4)
    gm <- as.numeric(bm(list(cube), 1L))
    gs <- as.numeric(bs(list(cube), 1L))
    expect_lt(max(abs(gm - ref$mean) / pmax(abs(ref$mean), 1)), 1e-5,
              label = paste0(nm, ": smoothed mean rel diff"))
    expect_lt(max(abs(gs - ref$sd) / pmax(ref$sd, 1e-9)), 1e-5,
              label = paste0(nm, ": smoothed sd rel diff"))
  }
})

test_that("per-year relative observation variance matches KFAS", {
  skip_if_not_installed("KFAS")
  set.seed(3)
  y <- .k_series()
  y[c(4, 11)] <- NaN
  r_rel <- stats::runif(15, 0.5, 3)
  r_rel[c(4, 11)] <- NaN                       # missing years: r irrelevant
  ref <- kfas_llt(y, 1, 0.01, h = 4 * ifelse(is.na(r_rel), 1, r_rel))
  cube <- array(y, c(15, 1, 1))
  rcube <- array(r_rel, c(15, 1, 1))
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
  skip_if_not_installed("KFAS")
  set.seed(5)
  T_ <- 12; ny <- 3; nx <- 2
  cube <- array(NA_real_, c(T_, ny, nx))
  for (j in seq_len(ny)) for (k in seq_len(nx)) {
    y <- .k_series(T_)
    y[sample(T_, sample(0:5, 1))] <- NaN
    cube[, j, k] <- y
  }
  gm <- .k_body("mean")(list(cube), 1L)
  for (j in seq_len(ny)) for (k in seq_len(nx)) {
    y <- cube[, j, k]
    if (sum(!is.na(y)) < 3) {
      expect_true(all(is.na(gm[, j, k])))
    } else {
      ref <- kfas_llt(y, 1, 0.01, h = 4)
      expect_lt(max(abs(gm[, j, k] - ref$mean) / pmax(abs(ref$mean), 1)),
                1e-5, label = sprintf("pixel (%d, %d)", j, k))
    }
  }
})

test_that("traced (PJRT) body matches the untraced oracle", {
  skip_if_not_installed("anvl")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")
  set.seed(6)
  cube <- array(.k_series(15 * 4 * 3), c(15, 4, 3))
  cube[sample(length(cube), 30)] <- NaN
  for (output in c("mean", "sd")) {
    body <- .k_body(output)
    jf <- g_jit(function(x) body(list(x), 1L))
    traced <- g_download(jf(g_upload(cube, "f32")))
    untraced <- body(list(cube), 1L)
    expect_identical(is.na(traced), is.na(untraced))
    # f32 input quantisation bounds the gap, not the f64 recursion
    expect_lt(max(abs(traced - untraced), na.rm = TRUE), 1e-4)
  }
})

test_that("kalman_smooth() through a full scan_over plan matches KFAS", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("KFAS")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")
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

  # spot-check one dense pixel directly against KFAS
  dense <- which(apply(!is.na(vals), c(2, 3), all), arr.ind = TRUE)
  skip_if(nrow(dense) == 0L, "no dense pixel in fixture")
  j <- dense[1, 1]; k <- dense[1, 2]
  ref <- kfas_llt(vals[, j, k], 1, 0.01, h = 4)
  expect_lt(max(abs(got_mean[, j, k] - ref$mean) / pmax(abs(ref$mean), 1)),
            1e-3)
})

test_that("kalman scan: distributed == single-threaded", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  b <- lazy_source(f)
  stk <- lazy_stack(list(a + 1, b * 2, a * b, a - b))
  sc <- scan_over(stk, kalman_llt(1, 0.1, 2), over = "t",
                  direction = "bidir")
  p <- plan_lazy(sc)
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-6)
})

test_that("kalman_llt validates its arguments", {
  expect_error(kalman_llt(0, 0.1, 2), "finite positive")
  expect_error(kalman_llt(1, 0.1, 2, kappa = -1), "finite positive")
  expect_error(kalman_llt(1, 0.1, 2, output = "variance"), "arg")
  body <- kalman_llt(1, 0.1, 2, out_dtype = "f64")
  cube <- array(stats::rnorm(12), c(4, 3, 1))
  expect_error(body(list(cube), 2L), "margin")
})

# -- robust reweighting (phase 4) ----------------------------------------------

# Faithful transcription of hutan's robust loop (smooth-stack.R:121-150)
# around the KFAS reference, with time-varying level noise.
kfas_llt_robust <- function(y, q_lvl, q_slp, h, iters = 2L,
                            thr = 3, infl = 100) {
  SSMtrend <- KFAS::SSMtrend
  T_ <- length(y)
  Q_scale <- rep(1, T_)
  out <- NULL
  for (it in seq_len(iters + 1L)) {
    m <- KFAS::SSModel(
      y ~ SSMtrend(degree = 2,
                   Q = list(array(q_lvl * Q_scale, c(1, 1, T_)),
                            matrix(q_slp))),
      H = array(h, c(1, 1, T_))
    )
    ks <- KFAS::KFS(m, smoothing = "state")
    out <- list(mean = as.numeric(ks$alphahat[, "level"]),
                sd = sqrt(pmax(ks$V[1, 1, ], 0)),
                q_years = which(Q_scale != 1))
    if (it > iters) break
    converged <- TRUE
    inn <- diff(out$mean)
    inn_sd <- stats::mad(inn, na.rm = TRUE)
    if (is.finite(inn_sd) && inn_sd > 0) {
      z <- abs(c(0, inn)) / inn_sd
      nq <- ifelse(z > thr, infl, 1)
      if (any(nq != Q_scale)) converged <- FALSE
      Q_scale <- nq
    }
    if (converged) break
  }
  out
}

test_that("robust reweighting matches hutan's loop around KFAS", {
  skip_if_not_installed("KFAS")
  set.seed(8)
  # series with injected level breaks (the robust loop's target)
  cases <- list(
    onebreak = { y <- .k_series(); y[8:15] <- y[8:15] + 25; y },
    twobreak = { y <- .k_series(); y[5:15] <- y[5:15] - 20
                 y[11:15] <- y[11:15] + 30; y },
    breakgap = { y <- .k_series(); y[9:15] <- y[9:15] + 25
                 y[c(3, 10, 11)] <- NaN; y },
    smooth   = .k_series()               # no break: loop converges pass 1
  )
  bm <- .k_body("mean", robust_iters = 2L)
  bs <- .k_body("sd", robust_iters = 2L)
  for (nm in names(cases)) {
    y <- cases[[nm]]
    cube <- array(y, c(length(y), 1, 1))
    ref <- kfas_llt_robust(y, q_lvl = 1, q_slp = 0.01, h = 4)
    gm <- as.numeric(bm(list(cube), 1L))
    gs <- as.numeric(bs(list(cube), 1L))
    expect_lt(max(abs(gm - ref$mean) / pmax(abs(ref$mean), 1)), 1e-5,
              label = paste0(nm, ": robust mean rel diff"))
    expect_lt(max(abs(gs - ref$sd) / pmax(ref$sd, 1e-9)), 1e-5,
              label = paste0(nm, ": robust sd rel diff"))
  }
  # sanity: the loop actually fired on the break series
  y <- cases$onebreak
  ref <- kfas_llt_robust(y, 1, 0.01, 4)
  expect_gt(length(ref$q_years), 0L)
  plain <- as.numeric(.k_body("mean")(list(array(y, c(15, 1, 1))), 1L))
  robust <- as.numeric(bm(list(array(y, c(15, 1, 1))), 1L))
  expect_gt(max(abs(plain - robust)), 0.1)
})

test_that("robust reweighting is per pixel in a batched cube", {
  skip_if_not_installed("KFAS")
  set.seed(9)
  y_break <- .k_series(); y_break[8:15] <- y_break[8:15] + 25
  y_plain <- .k_series()
  cube <- array(NA_real_, c(15, 2, 1))
  cube[, 1, 1] <- y_break
  cube[, 2, 1] <- y_plain
  gm <- .k_body("mean", robust_iters = 2L)(list(cube), 1L)
  for (j in 1:2) {
    ref <- kfas_llt_robust(cube[, j, 1], 1, 0.01, 4)
    expect_lt(max(abs(gm[, j, 1] - ref$mean) / pmax(abs(ref$mean), 1)),
              1e-5, label = paste("pixel", j))
  }
})

test_that("robust traced (PJRT) body matches the untraced oracle", {
  skip_if_not_installed("anvl")
  skip_if(!garry::.g_has_nv_scan(), "installed anvl lacks nv_scan")
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
