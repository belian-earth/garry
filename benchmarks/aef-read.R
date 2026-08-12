# Standalone AEF read + dequantize benchmark: the lazy_dataset multi-band
# fan-out vs one multithreaded GDAL warp.
#
# Workload: read a 2048x2048, 30 m window of ONE Alpha Earth Foundations (AEF)
# annual embedding tile -- 64 Int8 bands in a single COG, ZSTD, stored south-up
# -- warp it onto a UTM analysis grid and apply the nonlinear AEF dequant
# ((x/127.5)^2)*sign(x). Public data (Source Cooperative, no auth).
#
# lazy_dataset(path) builds one band per file band; at collect() the per-band
# reads fan out across the reader pool (one handle per daemon, range requests
# in parallel: design/gdal-multiband-fanout.md). The dequant is applied as a
# pipeline map (lazy_map), which garry fuses onto the read (no separate decode
# pass). The comparator is one multithreaded GDAL multi-band warp (all 64
# bands, one open: the good single-process GDAL baseline) followed by a garry
# anvl dequant of the returned buffer. garry's old per-band SEQUENTIAL path
# (64 warps, one at a time) is added last for scale, off by default
# (AEF_PERBAND=1 to include it -- it is slow).
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

# Decode is a pipeline map, not a reader arg; garry fuses it onto the read.
read_dequant <- function()
  collect(lazy_map(lazy_dataset(tile, grid), fn = dequantize_aef,
                   dtype = "f32"),
          distributed = TRUE)

cat("warming up (TLS, GDAL header cache, daemons)...\n")
invisible(read_dequant())
invisible(gdalraster::warp(vsi, tempfile(fileext = ".tif"), t_srs = tsrs,
          cl_arg = c("-te", te, "-ts", ts, "-b", "1", gcfg), quiet = TRUE))

# --- lazy_dataset: fan-out 64-band read + fused dequant, end to end ---------
t_ds <- best(read_dequant)
cat(sprintf("RESULT lazy_dataset (fan-out 64-band read + fused dequant): %.1fs\n", t_ds))

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
cat(sprintf("RESULT GDAL 1x multi-band warp + anvl dequant:              %.1fs\n", t_gd))

# --- optional: the old per-band SEQUENTIAL path (64 GDAL warps) -------------
if (identical(Sys.getenv("AEF_PERBAND"), "1")) {
  t_pb <- best(function() for (b in 1:64)
    gdalraster::warp(vsi, tempfile(fileext = ".tif"), t_srs = tsrs,
      cl_arg = c("-b", b, "-te", te, "-ts", ts, "-r", "near", "-of", "GTiff"),
      quiet = TRUE))
  cat(sprintf("RESULT GDAL 64x sequential per-band warp:                   %.1fs\n", t_pb))
}

cat(sprintf(
  "\n== AEF %dx%d @ 30m, 64 bands, best of %d ==\n   lazy_dataset %.1fs  vs  GDAL multiband %.1fs  (%.2fx)\n",
  ts[1], ts[2], reps, t_ds, t_gd, t_gd / t_ds))
