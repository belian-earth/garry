# PoC checkpoint demo (end of Phase 5).
#
# Real data: an HLS median composite over the Kuamut basin produced by
# vrtility (bands: 3 = NIR, 4 = RED, 9 = NDVI-as-computed-upstream).
# Pipeline: NDVI -> 5x5 focal mean -> global stats, executed lazily in
# chunks through anvl/XLA kernels, with plan introspection first.
#
# Run: Rscript design/poc-demo.R [path-to-composite.tif]

suppressMessages({
  library(garry)
})

args <- commandArgs(trailingOnly = TRUE)
path <- if (length(args) >= 1) args[[1]] else
  "/home/hugh/Downloads/Kuamut_HSL_Median2023_V6.tif"
stopifnot(file.exists(path))

nir <- lazy_source(path, band = 3L)
red <- lazy_source(path, band = 4L)

ndvi <- (nir - red) / (nir + red)
smooth <- focal(ndvi, fn = function(sh) Reduce(`+`, sh) / 25, radius = 2L)
mean_ndvi <- reduce_over(smooth, "mean", c("x", "y"), nan_rm = TRUE)

cat("== Lazy pipeline ==\n")
print(smooth)

cat("\n== Plan ==\n")
p <- collect(mean_ndvi, plan_only = TRUE)
print(p)

cat("\n== Execute: smoothed NDVI raster ==\n")
t1 <- system.time(sm <- collect(smooth))
cat(sprintf("collect(smooth): %.2fs for %d x %d px in chunks\n",
            t1[["elapsed"]], nrow(sm), ncol(sm)))

cat("\n== Execute: global mean of smoothed NDVI ==\n")
t2 <- system.time(mu <- collect(mean_ndvi))
cat(sprintf("mean(NDVI_5x5) = %.6f  (%.2fs)\n", mu, t2[["elapsed"]]))

cat("\n== Validation ==\n")
# 1. Against the NDVI band vrtility computed at composite time.
stored <- gdal_read_window(path, 9L, 0L, 0L, ncol(sm), nrow(sm))
ours <- collect(ndvi)
ok <- !is.nan(ours) & !is.nan(stored)
cat(sprintf("NDVI vs stored band 9: max |diff| = %.2e over %d px\n",
            max(abs(ours[ok] - stored[ok])), sum(ok)))

# 2. Against terra, if installed.
if (requireNamespace("terra", quietly = TRUE)) {
  tt <- system.time({
    r <- terra::rast(path)
    tndvi <- (r[[3]] - r[[4]]) / (r[[3]] + r[[4]])
    tsm <- terra::focal(tndvi, w = 5, fun = "mean", na.rm = FALSE,
                        fillvalue = NaN)
    tmu <- terra::global(tsm, "mean", na.rm = TRUE)[1, 1]
  })
  cat(sprintf("terra reference:  mean = %.6f  (%.2fs)\n", tmu, tt[["elapsed"]]))
  cat(sprintf("garry vs terra:   |diff| = %.2e\n", abs(mu - tmu)))
}
