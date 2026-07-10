# garry equivalent of vrtility/benchmarks/benchmark_r_vrtility.R
#
# Workload: HLS S30 (Planetary Computer) over the Kuamut-adjacent PNG
# bbox, all of 2023; Fmask bits 0-3 (cirrus/cloud/adjacent/shadow)
# masked to nodata, with odc-algo's mask cleanup — opening(2) then
# dilation(3), disk structuring elements — applied to the bad-pixel
# mask (phase 11.2 parity: the ODC baseline has always done this;
# the vrtility baseline does NOT, so it reads slightly faster than a
# like-for-like run would). Warped onto the EPSG:20255 30 m analysis
# grid; per-day mosaics; temporal median composite per band; GTiff
# out. Set GARRY_BENCH_MORPH=0 for the historical no-cleanup shape.
#
# References measured on the same machine (vrtility/benchmarks):
#   ODC + dask (Python): 28.35 s   (three bands, one pass)
#   vrtility:            20.74 s   (three bands, one pass)
#
# Run:  Rscript benchmarks/hls-median-composite.R [daemons] [bands...]
# daemons is "READ+COMPUTE" pools (default 16+6: 16 fetch streams,
# 6 XLA daemons; comp tasks spill to idle readers after the drain)
# or a single number for one shared pool.
# e.g.  Rscript benchmarks/hls-median-composite.R 16+6 B04 B03 B02

suppressMessages(library(garry))

args <- commandArgs(trailingOnly = TRUE)
daemons_arg <- if (length(args) >= 1) args[[1]] else "16+6"
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
# (Trimming below 256 measured inert in phase 10b: whole-window reads
# stream through without ever filling the cache.)
Sys.setenv(GDAL_CACHEMAX = "256")
# Return freed compute buffers to the OS. glibc malloc retains large
# freed allocations in arenas: a daemon that ran one fused chunk sat
# at ~650 MB anon forever (measured), and consecutive chunks stacked
# further. With a 128 KB mmap/trim threshold big buffers are mmap'd
# and really freed (paired with the gc between compute tasks in the
# scheduler); fleet peak 9.3-9.8 -> 7.0 GB at wall parity. Must be in
# the env BEFORE daemons() so daemon processes inherit it at exec.
Sys.setenv(MALLOC_MMAP_THRESHOLD_ = "131072",
           MALLOC_TRIM_THRESHOLD_ = "131072")
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

# Split pools (phase 11.1): readers never load PJRT (~60 MB base +
# drain growth each) and saturate the link; 3 compute daemons confine
# the fused chunks' working sets and get their stage kernels
# pre-compiled while the drain runs. Measured 6.4 GB fleet peak vs
# 9.3-9.8 single-pool, same-or-better wall.
if (grepl("+", daemons_arg, fixed = TRUE)) {
  np <- as.integer(strsplit(daemons_arg, "+", fixed = TRUE)[[1]])
  garry_daemons(np[[1]], np[[2]])
} else {
  mirai::daemons(as.integer(daemons_arg))
}

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
if (nzchar(Sys.getenv("GARRY_TASK_LOG")))
  options(garry.task_log = Sys.getenv("GARRY_TASK_LOG"))
# GARRY_DEVICE=cuda runs the fused compute stages on the GPU (11.5);
# use a small compute pool, e.g. 12+2 — chunks share GPU memory.
if (nzchar(Sys.getenv("GARRY_DEVICE")))
  options(garry.device = Sys.getenv("GARRY_DEVICE"))
# Phase 12c: GARRY_STORE_VALUES=raw|double|auto flips the f32 raw store.
if (nzchar(Sys.getenv("GARRY_STORE_VALUES")))
  options(garry.store_values = Sys.getenv("GARRY_STORE_VALUES"))
# Phase 12d GDAL-direct composite fast path (composite shape only).
# GDAL-direct is default ON; GARRY_COMPOSITE_DIRECT=0 forces the scheduler.
if (nzchar(Sys.getenv("GARRY_COMPOSITE_DIRECT")))
  options(garry.composite_direct = Sys.getenv("GARRY_COMPOSITE_DIRECT") != "0")
if (nzchar(Sys.getenv("GARRY_GD_PARALLEL")))
  options(garry.gd_parallel = TRUE)

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

  # One shared IR graph: the cleaned mask below is then a single
  # subgraph consumed by every band's masking map (computed and
  # materialised once per slice), instead of re-imported per band —
  # cross-graph import only dedups sources (D6), not computed chains.
  G <- graph_new()
  slice_of <- function(asset, sl, nodata = NULL) {
    lazy_source(
      paste0("GTI:", idx[[asset]]),
      graph = G,
      nodata = nodata,
      open_options = c(
        gti_open_options(target,
                         filter = sprintf("slice = '%s'", sl),
                         sort_field = "datetime"),
        "NUM_THREADS=2"),
      grid = meta[[asset]]$grid,
      block_dim = meta[[asset]]$block_dim)
  }

  # Mask cleanup (odc-algo mask_cleanup parity): binary morphology on
  # the bad-pixel mask with disk structuring elements. Erosion of a
  # 0/1 mask is the product over the disk offsets; dilation is its
  # dual. The whole chain (bitand map + three focals, halo 2+2+3=7)
  # fuses into one Fmask-source-fed stage (D11), materialised once
  # per slice and shared by all bands. NaN (Fmask fill AND beyond-
  # edge halo pad) maps to 0 = clear, matching scipy's constant-0
  # border; true fill pixels are -9999 in the band data anyway.
  morph <- !identical(Sys.getenv("GARRY_BENCH_MORPH"), "0")
  disk_sel <- function(r) {
    o <- expand.grid(dx = -r:r, dy = -r:r)
    which(o$dx^2 + o$dy^2 <= r^2)
  }
  erode <- function(x, r) {
    sel <- disk_sel(r)
    focal(x, radius = as.integer(r),
          fn = function(sh) Reduce(`*`, sh[sel]))
  }
  dilate <- function(x, r) {
    sel <- disk_sel(r)
    focal(x, radius = as.integer(r),
          fn = function(sh) 1 - Reduce(`*`, lapply(sh[sel],
                                                   function(s) 1 - s)))
  }
  bad_of <- function(sl) {
    bad <- lazy_map(
      slice_of("Fmask", sl, nodata = 255),   # f32; fill/halo -> NaN
      dtype = "f32",
      fn = function(f) {
        fc <- g_ifelse(g_is_nodata(f), 0, f)
        g_cast(g_bitand(g_cast(fc, "i32"), 15L) > 0, "f32")
      })
    if (!morph) return(bad)
    bad |> erode(2) |> dilate(2) |> dilate(3)   # opening(2), dilation(3)
  }

  # One composite per band; then ONE collect over the band stack. The
  # merged graph dedups the shared Fmask subgraph — the cleaned mask
  # is computed once per slice, not per band — and a single plan puts
  # every band's reads into the scheduler ready-queue together,
  # keeping the network saturated end to end.
  cleaned <- lapply(slices, bad_of)
  names(cleaned) <- slices
  composites <- lapply(bands, function(band) {
    masked <- lapply(slices, function(sl) {
      lazy_map(
        slice_of(band, sl, nodata = -9999),   # reflectance: -9999 -> NaN
        cleaned[[sl]],
        dtype = "f32",
        fn = function(x, cl) g_ifelse(cl > 0.5, NaN, x))
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
cat(sprintf("processing time (garry, %s, daemons %s): %.2fs\n",
            paste(bands, collapse = "+"), daemons_arg, t_all[["elapsed"]]))
if (grepl("+", daemons_arg, fixed = TRUE)) garry_daemons(0, 0) else
  mirai::daemons(0)
