#!/usr/bin/env Rscript
# Benchmark: rustyfilters::rf_bilateral (the hutan spatial-context path)
# vs garry's fused bilateral_focal() -- the question is whether the Rust
# kernel's raw speed survives the materialise-and-reread it forces, versus
# XLA fusing the filter into the read + MLP predict.
#
# Workload (hutan bilateral_context_rast + predict_mlp_raster shape):
# an n-band embedding stack -> per-band 3x3 bilateral -> MLP over
# [raw | context] (2n features) -> one prediction band.
#
# Arms:
#   rf     rustyfilters per band (rayon, all cores) -> write the 2n-band
#          context GTiff -> garry mlp_project plan over that file
#          (the hutan pipeline shape: filter materialised between stages)
#   garry  ONE fused plan: read -> bilateral_focal per band -> stack ->
#          mlp_project -> collect (no intermediate raster)
# plus a kernel-only microbench (single 2048^2 band, filter alone, no IO).
#
# Run:  Rscript benchmarks/bilateral-context-bench.R [n_bands [side]]
# Defaults 24 bands, 2048^2. KALMAN_BENCH_CORES-style knob: BILAT_BENCH_CORES
# (compute daemons for both arms' garry plans, default 8).

suppressMessages(library(garry))
stopifnot(requireNamespace("rustyfilters", quietly = TRUE))

args <- commandArgs(trailingOnly = TRUE)
n_feat <- if (length(args) >= 1) as.integer(args[[1]]) else 24L
side <- if (length(args) >= 2) as.integer(args[[2]]) else 2048L
cores <- as.integer(Sys.getenv("BILAT_BENCH_CORES", "8"))
sigma_r <- 1.5; sigma_d <- 1

# -- synthetic embedding stack ---------------------------------------------------
src_path <- file.path(tempdir(), sprintf("bilat-src-%d-%d.tif", n_feat, side))
if (!file.exists(src_path)) {
  set.seed(1)
  ds <- gdalraster::create("GTiff", src_path, side, side, n_feat, "Float32",
                           options = c("TILED=YES"), return_obj = TRUE)
  ds$setGeoTransform(c(500000, 30, 0, 4600000, 0, -30))
  ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  base <- matrix(rnorm(side * side), side, side)
  for (b in seq_len(n_feat)) {
    v <- 0.7 * base + 0.3 * matrix(rnorm(side * side), side, side)
    v[sample(side * side, side)] <- NaN
    ds$write(b, 0, 0, side, side, as.numeric(t(v)))
  }
  ds$close()
}
grid <- grid_spec("EPSG:32632",
                  extent = c(500000, 4600000 - side * 30,
                             500000 + side * 30, 4600000),
                  dims = c(x = side, y = side))
cat(sprintf("stack: %d bands x %d^2, sigma_r %.2f, %d compute daemons, %d rf threads\n",
            n_feat, side, sigma_r, cores, rustyfilters::rf_get_threads()))

# MLP over [raw | context] = 2n features
set.seed(2)
hidden <- 64L
mlp_w <- list(matrix(rnorm(hidden * 2L * n_feat, sd = 0.2), hidden, 2L * n_feat),
              matrix(rnorm(hidden * hidden, sd = 0.2), hidden, hidden),
              matrix(rnorm(hidden, sd = 0.2), 1, hidden))
mlp_b <- list(rnorm(hidden), rnorm(hidden), rnorm(1))

tick <- function() proc.time()[["elapsed"]]

# -- kernel-only microbench -------------------------------------------------------
mb <- {
  src <- new(gdalraster::GDALRaster, src_path)
  m <- matrix(src$read(1, 0, 0, side, side, side, side), side, side, byrow = TRUE)
  src$close()
  t0 <- tick()
  rf1 <- rustyfilters::rf_bilateral(m, sigma_d = sigma_d, sigma_r = sigma_r,
                                    window = 3L)
  t_rf <- tick() - t0
  fn <- bilateral_focal(sigma_r = sigma_r, sigma_d = sigma_d)
  off <- expand.grid(dx = -1:1, dy = -1:1)
  jf <- g_jit(function(xpad) {
    shifts <- lapply(seq_len(9L), function(k)
      g_shift_slice(xpad, off$dy[k], off$dx[k], side, side, 1L))
    fn(shifts)
  })
  xp <- g_upload(g_pad(m, 1L, NaN), "f32")
  invisible(g_download(jf(xp)))                  # warm (compile)
  t0 <- tick()
  g1 <- g_download(jf(xp))
  t_g <- tick() - t0
  d <- max(abs(g1 - unclass(rf1)[seq_along(g1)]), na.rm = TRUE)
  cat(sprintf("kernel-only (1 band, no IO): rustyfilters %.3f s | garry XLA %.3f s | max diff %.2g\n",
              t_rf, t_g, d))
}

garry_daemons(2, cores)
on.exit(garry_daemons(0, 0), add = TRUE)

mlp_over <- function(inputs) {
  cube <- lazy_stack(inputs, along = "band")
  reduce_over(cube, mlp_project(mlp_w, mlp_b), over = "band")
}

# -- arm rf: filter via rustyfilters, materialise, then predict -------------------
ctx_path <- file.path(tempdir(), "bilat-ctx.tif")
t0 <- tick()
{
  src <- new(gdalraster::GDALRaster, src_path)
  out <- gdalraster::create("GTiff", ctx_path, side, side, 2L * n_feat,
                            "Float32", options = c("TILED=YES"),
                            return_obj = TRUE)
  out$setGeoTransform(c(500000, 30, 0, 4600000, 0, -30))
  out$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
  for (b in seq_len(n_feat)) {
    v <- matrix(src$read(b, 0, 0, side, side, side, side), side, side,
                byrow = TRUE)
    fb <- rustyfilters::rf_bilateral(v, sigma_d = sigma_d, sigma_r = sigma_r,
                                     window = 3L)
    out$write(b, 0, 0, side, side, as.numeric(t(v)))
    out$write(n_feat + b, 0, 0, side, side, as.numeric(t(unclass(fb))))
  }
  src$close(); out$close()
}
t_rf_filter <- tick() - t0
t0 <- tick()
g <- graph_new()
feats <- lapply(seq_len(2L * n_feat), function(b)
  lazy_source(ctx_path, band = b, graph = g))
rf_out <- file.path(tempdir(), "bilat-pred-rf.tif")
collect(mlp_over(feats), path = rf_out)
t_rf_pred <- tick() - t0
cat(sprintf("rf arm   : filter+write %.1f s + predict %.1f s = %.1f s\n",
            t_rf_filter, t_rf_pred, t_rf_filter + t_rf_pred))

# -- arm garry: one fused plan -----------------------------------------------------
t0 <- tick()
g <- graph_new()
raw <- lapply(seq_len(n_feat), function(b)
  lazy_source(src_path, band = b, graph = g))
ctx <- lapply(raw, function(lr)
  focal(lr, fn = bilateral_focal(sigma_r = sigma_r, sigma_d = sigma_d),
        radius = 1L))
ga_out <- file.path(tempdir(), "bilat-pred-garry.tif")
collect(mlp_over(c(raw, ctx)), path = ga_out)
t_garry <- tick() - t0
cat(sprintf("garry arm: fused filter+predict = %.1f s  (%.2fx vs rf arm)\n",
            t_garry, (t_rf_filter + t_rf_pred) / t_garry))

# -- fidelity ----------------------------------------------------------------------
rd <- function(f) {
  ds <- new(gdalraster::GDALRaster, f)
  on.exit(ds$close())
  ds$read(1, 0, 0, side, side, side, side)
}
d <- abs(rd(rf_out) - rd(ga_out))
cat(sprintf("fidelity: max |diff| %.3g  p99 %.3g\n",
            suppressWarnings(max(d, na.rm = TRUE)),
            stats::quantile(d, 0.99, na.rm = TRUE)))
