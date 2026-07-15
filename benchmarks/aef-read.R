# Standalone AEF read + dequantize benchmark for garry's lazy_cog (cptkirk).
#
# Workload: read a 2048x2048, 30 m window of ONE Alpha Earth Foundations (AEF)
# annual embedding tile -- 64 Int8 bands in a single COG, ZSTD, stored south-up
# -- warp it onto a UTM analysis grid and apply the nonlinear AEF dequant
# ((x/127.5)^2)*sign(x). Public data (Source Cooperative, no auth).
#
# lazy_cog routes the multi-band read through cptkirk -- one open, all 64 band
# planes streamed concurrently -- and FUSES the dequant onto the read as an anvl
# map (no separate decode pass). The comparator is one multithreaded GDAL
# multi-band warp (all 64 bands, one open: the good GDAL baseline) followed by a
# garry anvl dequant of the returned buffer. That cptkirk-vs-one-GDAL-warp gap is
# the decisive number; garry's old per-band path (64 warps) is added last for
# scale, off by default (AEF_PERBAND=1 to include it -- it is slow).
#
# Run:  Rscript benchmarks/aef-read.R [daemons]
#       AEF_REPS=3 (best-of), AEF_PERBAND=1 (add the 64x per-band baseline).

suppressMessages({library(garry); library(gdalraster)})

args <- commandArgs(trailingOnly = TRUE)
daemons_arg <- if (length(args) >= 1) args[[1]] else "auto"

tile <- paste0("https://data.source.coop/tge-labs/aef/v1/annual/2021/36S/",
               "xekh5rjs4wg6wb9b4-0000000000-0000000000.tiff")
vsi  <- paste0("/vsicurl/", tile)
tsrs <- "EPSG:32736"
te   <- c(510000, 8540000, 571440, 8601440)      # 61.44 km window within the tile
ts   <- c(2048L, 2048L)
grid <- grid_spec(tsrs, extent = te, dims = ts, dtype = "f32")

reps  <- as.integer(Sys.getenv("AEF_REPS", "3"))
best  <- function(f) min(replicate(reps, system.time(f())[["elapsed"]]))
gcfg  <- c("-r", "near", "-of", "GTiff", "-multi", "-wo", "NUM_THREADS=ALL_CPUS")

if (identical(daemons_arg, "auto")) garry_daemons() else {
  np <- as.integer(strsplit(daemons_arg, "+", fixed = TRUE)[[1]]); garry_daemons(np[[1]], np[[2]])
}
on.exit(garry_daemons(0, 0), add = TRUE)
options(garry.progress = FALSE)

cat("warming up (TLS, GDAL header cache, daemons)...\n")
invisible(collect(lazy_cog(tile, grid, dequant = dequantize_aef), distributed = TRUE))
invisible(gdalraster::warp(vsi, tempfile(fileext = ".tif"), t_srs = tsrs,
          cl_arg = c("-te", te, "-ts", ts, "-b", "1", gcfg), quiet = TRUE))

# --- lazy_cog: cptkirk read + fused dequant, end to end ---------------------
t_ck <- best(function()
  collect(lazy_cog(tile, grid, dequant = dequantize_aef), distributed = TRUE))
cat(sprintf("RESULT lazy_cog (cptkirk 64-band read + fused dequant): %.1fs\n", t_ck))

# --- baseline: one GDAL multi-band warp (all 64 bands) + garry anvl dequant --
gdal_multiband_dequant <- function() {
  dg <- tempfile(fileext = ".tif")
  gdalraster::warp(vsi, dg, t_srs = tsrs, cl_arg = c("-te", te, "-ts", ts, gcfg),
                   quiet = TRUE)
  d <- new(GDALRaster, dg); nb <- d$getRasterCount()
  mats <- lapply(seq_len(nb), function(b)
    d$read(band = b, xoff = 0, yoff = 0, xsize = ts[1], ysize = ts[2],
           out_xsize = ts[1], out_ysize = ts[2]))
  d$close()
  cube <- g_upload_raw(writeBin(as.numeric(unlist(mats)), raw(), size = 4L),
                       "f32", c(nb, ts[2], ts[1]))
  g_download(g_jit(function(inp) dequantize_aef(inp[[1L]]))(list(cube)))
}
t_gd <- best(gdal_multiband_dequant)
cat(sprintf("RESULT GDAL 1x multi-band warp + anvl dequant:          %.1fs\n", t_gd))

# --- optional: garry's old per-band path (64 GDAL warps) --------------------
if (identical(Sys.getenv("AEF_PERBAND"), "1")) {
  t_pb <- best(function() for (b in 1:64)
    gdalraster::warp(vsi, tempfile(fileext = ".tif"), t_srs = tsrs,
      cl_arg = c("-b", b, "-te", te, "-ts", ts, "-r", "near", "-of", "GTiff"),
      quiet = TRUE))
  cat(sprintf("RESULT GDAL 64x per-band warp:                          %.1fs\n", t_pb))
}

cat(sprintf(
  "\n== AEF %dx%d @ 30m, 64 bands, best of %d ==\n   lazy_cog %.1fs  vs  GDAL multiband %.1fs  (%.2fx)\n",
  ts[1], ts[2], reps, t_ck, t_gd, t_gd / t_ck))
