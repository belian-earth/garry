#!/usr/bin/env Rscript
# Validate garry's kalman_llt() against hutan's per-pixel KFAS smoother on
# REAL pixel series sampled from a hutan annual stack. Out of CI: needs a
# tile on disk plus the hutan package. The CI-facing synthetic validation
# lives in tests/testthat/test-scan-kalman-kfas.R.
#
# Usage:
#   Rscript benchmarks/kalman-kfas-validate.R <rh98_stack.tif> <qa_stack.tif> \
#       [n_pixels = 2000] [robust_iters = 0]
#
# Reports max / p99 / p50 absolute and relative divergence of the smoothed
# mean and sd, and asserts identical NaN patterns.

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) stop("usage: kalman-kfas-validate.R <rh98> <qa> [n] [robust_iters]")
rh98_path <- args[[1]]
qa_path <- args[[2]]
n_pixels <- if (length(args) >= 3) as.integer(args[[3]]) else 2000L
robust_iters <- if (length(args) >= 4) as.integer(args[[4]]) else 0L

suppressMessages({
  library(garry)
  library(KFAS)
})
stopifnot(requireNamespace("hutan", quietly = TRUE))

# -- sample valid pixels (both stacks finite in band 1) ------------------------
ds_y <- new(gdalraster::GDALRaster, rh98_path)
ds_q <- new(gdalraster::GDALRaster, qa_path)
T_ <- ds_y$getRasterCount()
stopifnot(T_ == ds_q$getRasterCount())
nx <- ds_y$getRasterXSize(); ny <- ds_y$getRasterYSize()

set.seed(1)
b1 <- ds_y$read(1, 0, 0, nx, ny, nx, ny)
q1 <- ds_q$read(1, 0, 0, nx, ny, nx, ny)
valid <- which(is.finite(b1) & is.finite(q1))
cells <- sample(valid, min(n_pixels, length(valid)))
cols <- (cells - 1L) %% nx
rows <- (cells - 1L) %/% nx

read_series <- function(ds) {
  out <- matrix(NA_real_, length(cells), T_)
  for (b in seq_len(T_)) {
    band <- ds$read(b, 0, 0, nx, ny, nx, ny)
    out[, b] <- band[cells]
  }
  out
}
Y <- read_series(ds_y)     # n x T
QA <- read_series(ds_q)
ds_y$close(); ds_q$close()

# -- hyperparameters: hutan's own MLE on the sample ----------------------------
hp <- hutan:::.fit_global_kalman_hyperparams(Y, QA, obs_var_scaling = "inv_qa",
                                             verbose = TRUE)
cat(sprintf("hyperparams: sigma_lvl %.4g sigma_slp %.4g sigma_obs %.4g\n",
            hp$sigma_lvl, hp$sigma_slp, hp$sigma_obs))

# -- reference: hutan's per-pixel KFAS smoother --------------------------------
tmpl <- hutan:::.make_llt_template(T_)
ref_mean <- matrix(NA_real_, length(cells), T_)
ref_sd <- matrix(NA_real_, length(cells), T_)
for (i in seq_len(length(cells))) {
  r <- hutan:::.kf_smooth_one_pixel(
    y = Y[i, ], qa = QA[i, ], hp = hp,
    obs_var_scaling = "inv_qa", robust_iters = robust_iters,
    tmpl = tmpl)
  ref_mean[i, ] <- r$mean
  ref_sd[i, ] <- r$sd
}

# -- garry: the batched untraced body, then the jitted body --------------------
# QA policy upstream of the scan body: H_t = sigma_obs^2 / qa_t, bad QA -> NaN y
r_rel <- 1 / QA
bad <- !is.finite(QA) | QA <= 0
Y[bad] <- NaN
r_rel[bad] <- NaN

cube_y <- array(t(Y), c(T_, length(cells), 1L))      # (t, pixel, 1)
cube_r <- array(t(r_rel), c(T_, length(cells), 1L))

run_garry <- function(traced) {
  out <- list()
  for (o in c("mean", "sd")) {
    body <- kalman_llt(hp$sigma_lvl, hp$sigma_slp, hp$sigma_obs,
                       output = o, robust_iters = robust_iters,
                       out_dtype = "f64")
    out[[o]] <- if (traced) {
      jf <- g_jit(function(y, r) body(list(y, r), 1L))
      g_download(jf(g_upload(cube_y, "f64"), g_upload(cube_r, "f64")))
    } else {
      body(list(cube_y, cube_r), 1L)
    }
  }
  out
}

report <- function(tag, got, ref) {
  ref_t <- t(ref)                                    # T x n -> match (t, pixel)
  d <- abs(got[, , 1] - ref_t)
  rel <- d / pmax(abs(ref_t), 1)
  nan_ok <- identical(is.na(got[, , 1]), is.na(ref_t))
  cat(sprintf("%-14s max %8.3g  p99 %8.3g  p50 %8.3g  (rel max %8.3g)  NaN pattern: %s\n",
              tag, max(d, na.rm = TRUE),
              stats::quantile(d, 0.99, na.rm = TRUE),
              stats::quantile(d, 0.5, na.rm = TRUE),
              max(rel, na.rm = TRUE),
              if (nan_ok) "identical" else "DIFFERS"))
}

g_r <- run_garry(traced = FALSE)
report("mean (oracle)", g_r$mean, ref_mean)
report("sd   (oracle)", g_r$sd, ref_sd)

if (requireNamespace("anvl", quietly = TRUE) && garry::.g_has_nv_scan()) {
  g_t <- run_garry(traced = TRUE)
  report("mean (PJRT)", g_t$mean, ref_mean)
  report("sd   (PJRT)", g_t$sd, ref_sd)
}
