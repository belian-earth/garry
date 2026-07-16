#!/usr/bin/env Rscript
# Benchmark: the garry ScanNode Kalman smoother vs hutan's per-pixel
# KFAS + mirai path -- the temporal smoother that motivated ScanNode
# (design/scan-node-design.md). End-to-end per arm: read the annual
# stack, smooth every pixel (robust LLT, mean + sd), write both outputs.
#
# Arms:
#   1. hutan::smooth_stack()          KFAS per pixel, mirai daemons (baseline)
#   2. garry scan_over(kalman_llt())  batched scan, CPU PJRT, mirai daemons
#   3. arm 2 with GARRY_DEVICE=cuda   one jitted while-loop per chunk on GPU
#
# Run:
#   Rscript benchmarks/kalman-smooth-bench.R [rh98_stack.tif [qa_stack.tif]]
# With no arguments a synthetic [15, 4096, 4096] Float32 stack (with NaN
# gaps and level breaks) is generated under tempdir(). Knobs:
#   KALMAN_BENCH_CORES   daemons per arm (default 8)
#   KALMAN_BENCH_ARMS    comma list, default "hutan,garry" (+ ",cuda" if set)
#   GARRY_DEVICE=cuda    adds the GPU arm
# The garry-vs-hutan max divergence is reported: the benchmark doubles as
# the live fidelity check on real tiles.

suppressMessages(library(garry))

args <- commandArgs(trailingOnly = TRUE)
cores <- as.integer(Sys.getenv("KALMAN_BENCH_CORES", "8"))
arms <- strsplit(Sys.getenv(
  "KALMAN_BENCH_ARMS",
  if (identical(Sys.getenv("GARRY_DEVICE"), "cuda")) "hutan,garry,cuda"
  else "hutan,garry"
), ",")[[1]]

# -- input stacks ---------------------------------------------------------------
if (length(args) >= 1) {
  rh98_path <- args[[1]]
  qa_path <- if (length(args) >= 2) args[[2]] else NULL
} else {
  message("no stack given: generating a synthetic [15, 4096, 4096] stack")
  T_ <- 15L; nx <- 4096L; ny <- 4096L
  rh98_path <- file.path(tempdir(), "kalman-bench-rh98.tif")
  qa_path <- NULL
  if (!file.exists(rh98_path)) {
    set.seed(1)
    ds <- gdalraster::create("GTiff", rh98_path, nx, ny, T_, "Float32",
                             options = c("TILED=YES", "COMPRESS=DEFLATE"),
                             return_obj = TRUE)
    ds$setGeoTransform(c(500000, 30, 0, 4600000, 0, -30))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:32632"))
    base <- matrix(runif(nx * ny, 5, 35), ny, nx)
    trend <- matrix(rnorm(nx * ny, 0, 0.3), ny, nx)
    for (t in seq_len(T_)) {
      v <- base + t * trend + matrix(rnorm(nx * ny, 0, 1.5), ny, nx)
      v[matrix(runif(nx * ny) < 0.15, ny, nx)] <- NaN   # gaps
      ds$write(t, 0, 0, nx, ny, as.numeric(t(v)))
    }
    ds$close()
  }
}

info <- new(gdalraster::GDALRaster, rh98_path)
T_ <- info$getRasterCount()
nx <- info$getRasterXSize(); ny <- info$getRasterYSize()
info$close()

# hutan requires a QA stack; without one, QA = 1 everywhere (H = sigma_obs^2,
# matching the garry arm's no-obs-var form).
if (is.null(qa_path) && "hutan" %in% arms) {
  qa_path <- file.path(tempdir(), "kalman-bench-qa1.tif")
  if (!file.exists(qa_path)) {
    ds <- gdalraster::create("GTiff", qa_path, nx, ny, T_, "Float32",
                             options = c("TILED=YES", "COMPRESS=DEFLATE"),
                             return_obj = TRUE)
    src <- new(gdalraster::GDALRaster, rh98_path)
    ds$setGeoTransform(src$getGeoTransform())
    ds$setProjection(src$getProjectionRef())
    src$close()
    ones <- rep(1, nx * ny)
    for (t in seq_len(T_)) ds$write(t, 0, 0, nx, ny, ones)
    ds$close()
  }
}
mpix_years <- nx * ny * T_ / 1e6
cat(sprintf("stack: %s  [%d x %d x %d]  (%.0f MPix-years)\n",
            rh98_path, T_, ny, nx, mpix_years))

# hyperparameters: fixed constants so every arm smooths the same model
# (on real tiles fit them once with hutan's MLE and paste here / extend
# this script to call hutan:::.fit_global_kalman_hyperparams).
hp <- list(sigma_lvl = 1, sigma_slp = 0.1, sigma_obs = 2)

peak_rss_mb <- function() {
  as.numeric(strsplit(readLines("/proc/self/status") |>
    grep("VmHWM", x = _, value = TRUE), "\\s+")[[1]][2]) / 1024
}

run_arm <- function(tag, fn) {
  gc()
  t0 <- proc.time()[["elapsed"]]
  out <- fn()
  dt <- proc.time()[["elapsed"]] - t0
  cat(sprintf("%-8s %8.1f s   %8.2f MPix-yr/s   peak RSS %6.0f MB\n",
              tag, dt, mpix_years / dt, peak_rss_mb()))
  out
}

results <- list()

# -- arm 1: hutan (KFAS per pixel) ----------------------------------------------
if ("hutan" %in% arms && requireNamespace("hutan", quietly = TRUE)) {
  fm <- file.path(tempdir(), "bench-hutan-mean.tif")
  fs <- file.path(tempdir(), "bench-hutan-sd.tif")
  results$hutan <- run_arm("hutan", function() {
    hutan::smooth_stack(
      rh98_stack = rh98_path, qa_stack = qa_path,
      years = seq_len(T_), hyperparams = hp, robust_iters = 2L,
      filename_mean = fm, filename_std = fs,
      cores = cores, verbose = FALSE)
    c(mean = fm, sd = fs)
  })
} else if ("hutan" %in% arms) {
  message("hutan not installed: skipping the baseline arm")
}

# -- arms 2/3: garry scan --------------------------------------------------------
garry_arm <- function(tag, device) {
  fm <- file.path(tempdir(), sprintf("bench-garry-%s-mean.tif", tag))
  fs <- file.path(tempdir(), sprintf("bench-garry-%s-sd.tif", tag))
  run_arm(tag, function() {
    old <- options(garry.device = device)
    on.exit(options(old), add = TRUE)
    garry_daemons(2, cores)
    on.exit(garry_daemons(0, 0), add = TRUE)
    g <- graph_new()
    stk <- lazy_stack(lapply(seq_len(T_), function(b)
      lazy_source(rh98_path, band = b, graph = g)), along = "t")
    sm <- kalman_smooth(stk, hp$sigma_lvl, hp$sigma_slp, hp$sigma_obs,
                        robust_iters = 2L)
    collect(sm$mean, path = fm)
    collect(sm$sd, path = fs)
    c(mean = fm, sd = fs)
  })
}
if ("garry" %in% arms) results$garry <- garry_arm("garry", "cpu")
if ("cuda" %in% arms) results$cuda <- garry_arm("cuda", "cuda")

# -- fidelity: garry vs hutan on a sample window ---------------------------------
if (!is.null(results$hutan) && !is.null(results$garry)) {
  w <- min(1024L, nx); h <- min(1024L, ny)
  rd <- function(f) {
    ds <- new(gdalraster::GDALRaster, f)
    on.exit(ds$close())
    vapply(seq_len(ds$getRasterCount()),
           function(b) ds$read(b, 0, 0, w, h, w, h), numeric(w * h))
  }
  for (o in c("mean", "sd")) {
    a <- rd(results$hutan[[o]]); b <- rd(results$garry[[o]])
    d <- abs(a - b)
    cat(sprintf("fidelity %-4s: max |diff| %.3g  p99 %.3g  NaN pattern %s\n",
                o, suppressWarnings(max(d, na.rm = TRUE)),
                stats::quantile(d, 0.99, na.rm = TRUE),
                if (identical(is.na(a), is.na(b))) "identical" else "DIFFERS"))
  }
}
# f64 on consumer GPUs runs at ~1/32 fp throughput; immaterial here (the
# kernel is tiny and the pipeline read-bound).
