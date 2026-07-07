# garry equivalent of vrtility/benchmarks/benchmark_r_vrtility.R
#
# Workload: HLS S30 (Planetary Computer) over the Kuamut-adjacent PNG
# bbox, all of 2023; Fmask bits 0-3 (cirrus/cloud/adjacent/shadow)
# masked to nodata; warped onto the EPSG:20255 30 m analysis grid;
# per-day mosaics; temporal median composite per band; GTiff out.
#
# References measured on the same machine (vrtility/benchmarks):
#   ODC + dask (Python): 28.35 s   (three bands, one pass)
#   vrtility:            20.74 s   (three bands, one pass)
#
# Run:  Rscript benchmarks/hls-median-composite.R [n_daemons] [bands...]
# e.g.  Rscript benchmarks/hls-median-composite.R 12 B04 B03 B02

suppressMessages(library(garry))

args <- commandArgs(trailingOnly = TRUE)
n_daemons <- if (length(args) >= 1) as.integer(args[[1]]) else 12L
bands <- if (length(args) >= 2) args[-1] else c("B04", "B03", "B02")

# GDAL/network tuning. Pre-signed hrefs (below) beat per-URL GDAL
# signing (VSICURL_PC_URL_SIGNING), which storms the MPC signing
# endpoint across daemons into 429s; note pre-signed tokens expire
# after ~1 h, so very long jobs should switch back to GDAL signing.
Sys.setenv(GDAL_HTTP_MULTIPLEX = "YES", GDAL_HTTP_VERSION = "2")
# odc-stac's measured retry cadence (10 x 0.5s), plus the timeouts odc
# omits: a stalled request should fail fast and retry, not hang a
# daemon.
Sys.setenv(GDAL_HTTP_MAX_RETRY = "10", GDAL_HTTP_RETRY_DELAY = "0.5",
           GDAL_HTTP_RETRY_CODES = "429,500,502,503",
           GDAL_HTTP_TIMEOUT = "60", GDAL_HTTP_CONNECTTIMEOUT = "10")
# GDAL's block cache defaults to 5% of RAM PER PROCESS; every daemon
# inherits this env, so cap it or n_daemons x 5% eats the machine.
Sys.setenv(GDAL_CACHEMAX = "256")
gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
gdalraster::set_config_option("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".tif")
# One 32 KB range at open captures a whole COG header (vs several 16 KB
# probes); per-open cost dominates GTI slice reads.
Sys.setenv(GDAL_INGESTED_BYTES_AT_OPEN = "32768")

# The analysis grid: everything downstream is pinned to it exactly.
target <- grid_spec(
  "EPSG:20255",
  extent = c(183060, 9144870, 220830, 9172800),
  dims = c((220830 - 183060) / 30, (9172800 - 9144870) / 30),
  dtype = "f32")

# --- Discovery (not timed, matching the reference benchmarks) ---------------
t_query <- system.time({
  its <- stac_query(
    bbox = c(144.13, -7.725, 144.47, -7.475),
    stac_source = "https://planetarycomputer.microsoft.com/api/stac/v1/",
    collection = "hls2-s30",
    start_date = "2023-01-01",
    end_date = "2023-12-31")
  its <- rstac::items_sign(its, rstac::sign_planetary_computer())

  src <- stac_sources(its, assets = c(bands, "Fmask")) |>
    stac_drop_duplicates() |>
    stac_time_slices("day")
})
slices <- sort(unique(src$slice))
cat(sprintf("STAC query: %.2fs; %d item-assets, %d day slices\n",
            t_query[["elapsed"]], nrow(src), length(slices)))

mirai::daemons(n_daemons)

# Reads are whole-window (read_target_px decoupling: one GTI mosaic
# open per slice x asset). Per-band fused stages start as soon as
# their own band's reads land (fusion never crosses a reduction into
# a join), so only the last band's compute tail runs after the drain.
# Fewer, bigger chunks win: each compute chunk pays a fixed
# per-input-file cost (measured: 20 chunks of 256px = 10s tail, 6
# chunks of 512px = 5.5s). The mori store keeps chunks in shared
# memory: reads share whole windows once, computes slice zero-copy,
# nothing round-trips the disk.
options(garry.chunk_target_px = 1.4e6, garry.progress = TRUE)
if (requireNamespace("mori", quietly = TRUE))
  options(garry.store = "mori")

t_all <- system.time({
  # One GTI index per asset; each day is a FILTERed mosaic of that
  # index, pinned to the target grid (mixed UTM zones warp per tile).
  idx <- lapply(c(bands, "Fmask"), function(a)
    stac_gti_index(src, a, crs = target@crs))
  names(idx) <- c(bands, "Fmask")

  # One metadata probe per asset (dtype / native block); the 220
  # per-slice sources then declare their grid instead of each opening
  # the mosaic to rediscover it (~0.1s x 220, serial, on the host).
  meta <- lapply(idx, function(p)
    gdal_grid_spec(paste0("GTI:", p),
                   open_options = gti_open_options(target)))

  slice_of <- function(asset, sl, nodata = NULL) {
    lazy_source(
      paste0("GTI:", idx[[asset]]),
      nodata = nodata,
      open_options = c(
        gti_open_options(target,
                         filter = sprintf("slice = '%s'", sl),
                         sort_field = "datetime"),
        "NUM_THREADS=2"),
      grid = meta[[asset]]$grid,
      block_dim = meta[[asset]]$block_dim)
  }

  # One composite per band; then ONE collect over the band stack. The
  # merged graph dedups the shared Fmask sources (read once, not per
  # band), and a single plan puts every band's reads into the scheduler
  # ready-queue together, keeping the network saturated end to end.
  composites <- lapply(bands, function(band) {
    masked <- lapply(slices, function(sl) {
      lazy_map(
        slice_of(band, sl, nodata = -9999),   # reflectance: -9999 -> NaN
        slice_of("Fmask", sl),                # u8 QA, no sentinel
        dtype = "f32",
        fn = function(x, f) {
          bad <- g_bitand(g_cast(f, "i32"), 15L) > 0
          g_ifelse(bad, NaN, x)
        })
    })
    lazy_stack(masked) |> reduce_over("median", "t", nan_rm = TRUE)
  })

  out <- if (length(composites) == 1L) composites[[1L]]
         else lazy_stack(composites, along = "band")

  cat("graph built; planning + executing...\n")
  collect(out,
          path = "composite_garry.tif",
          nodata = -9999,
          distributed = TRUE)
})
cat(sprintf("processing time (garry, %s, %d daemons): %.2fs\n",
            paste(bands, collapse = "+"), n_daemons, t_all[["elapsed"]]))
mirai::daemons(0)
