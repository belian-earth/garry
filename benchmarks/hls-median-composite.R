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
# daemons defaults to "auto" (garry_daemons() sizes read/compute to the
# machine and applies the GDAL/malloc defaults); pass "READ+COMPUTE" (e.g.
# 16+20) to pin the pools. GARRY_DEVICE=cuda runs compute on the GPU (pass a
# small explicit pool, the daemons share one GPU); GARRY_BENCH_MORPH=0 drops
# the mask cleanup.
# e.g.  Rscript benchmarks/hls-median-composite.R auto B04 B03 B02

suppressMessages(library(garry))

args <- commandArgs(trailingOnly = TRUE)
daemons_arg <- if (length(args) >= 1) args[[1]] else "auto"
bands <- if (length(args) >= 2) args[-1] else c("B04", "B03", "B02")
device <- Sys.getenv("GARRY_DEVICE", "cpu") # "cpu" or "cuda" (GPU compute)

# No GDAL/network preamble: garry_daemons() (below) applies the remote-COG GDAL
# config (HTTP/2 multiplex, the odc-stac retry cadence, a capped block cache,
# fast COG opens) and the glibc malloc thresholds on the daemons. Discovery
# below uses pre-signed hrefs (rstac::items_sign) -- per-URL GDAL signing storms
# the MPC signing endpoint into 429s across daemons; tokens expire after ~1 h,
# so very long jobs should switch back to GDAL signing.

# The analysis grid: everything downstream is pinned to it exactly.
target <- grid_spec(
  "EPSG:20255",
  extent = c(183060, 9144870, 220830, 9172800),
  dims = c((220830 - 183060) / 30, (9172800 - 9144870) / 30),
  dtype = "f32"
)

# --- Discovery (not timed, matching the reference benchmarks) ---------------
t_query <- system.time({
  its <- stac_query(
    bbox = c(144.13, -7.725, 144.47, -7.475),
    stac_source = "https://planetarycomputer.microsoft.com/api/stac/v1/",
    collection = "hls2-s30",
    start_date = "2023-01-01",
    end_date = "2023-12-31"
  )
  its <- rstac::items_sign(its, rstac::sign_planetary_computer())

  src <- stac_sources(its, assets = c(bands, "Fmask")) |>
    stac_drop_duplicates() |>
    stac_time_slices("day")
})
slices <- sort(unique(src$slice))
cat(sprintf(
  "STAC query: %.2fs; %d item-assets, %d day slices\n",
  t_query[["elapsed"]],
  nrow(src),
  length(slices)
))

# Split read/compute pools: readers stay PJRT-free and saturate the link, the
# compute pool runs the XLA medians. "auto" sizes both to the machine (and sets
# the GDAL/malloc defaults); "READ+COMPUTE" pins them.
if (identical(daemons_arg, "auto")) {
  garry_daemons()
} else {
  np <- as.integer(strsplit(daemons_arg, "+", fixed = TRUE)[[1]])
  garry_daemons(np[[1]], np[[2]])
}

# The GDAL-direct composite pipeline is the default path; progress prints the
# per-phase [gdal-direct] timings.
options(garry.progress = TRUE, garry.device = device)

t_all <- system.time({
  # One GTI index per asset; each day is a FILTERed mosaic of that
  # index, pinned to the target grid (mixed UTM zones warp per tile).
  idx <- lapply(c(bands, "Fmask"), function(a) {
    stac_gti_index(src, a, crs = target@crs)
  })
  names(idx) <- c(bands, "Fmask")

  # One metadata probe per asset (dtype / native block); the 220
  # per-slice sources then declare their grid instead of each opening
  # the mosaic to rediscover it (~0.1s x 220, serial, on the host).
  meta <- lapply(idx, function(p) {
    gdal_grid_spec(paste0("GTI:", p), open_options = gti_open_options(target))
  })

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
        gti_open_options(
          target,
          filter = sprintf("slice = '%s'", sl),
          sort_field = "datetime"
        ),
        "NUM_THREADS=2"
      ),
      grid = meta[[asset]]$grid,
      block_dim = meta[[asset]]$block_dim
    )
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
    focal(x, radius = as.integer(r), fn = function(sh) Reduce(`*`, sh[sel]))
  }
  dilate <- function(x, r) {
    sel <- disk_sel(r)
    focal(x, radius = as.integer(r), fn = function(sh) {
      1 - Reduce(`*`, lapply(sh[sel], function(s) 1 - s))
    })
  }
  bad_of <- function(sl) {
    bad <- lazy_map(
      slice_of("Fmask", sl, nodata = 255), # f32; fill/halo -> NaN
      dtype = "f32",
      fn = function(f) {
        fc <- g_ifelse(g_is_nodata(f), 0, f)
        g_cast(g_bitand(g_cast(fc, "i32"), 15L) > 0, "f32")
      }
    )
    if (!morph) {
      return(bad)
    }
    bad |>
      erode(2) |>
      dilate(2) |>
      dilate(3) # opening(2), dilation(3)
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
        slice_of(band, sl, nodata = -9999), # reflectance: -9999 -> NaN
        cleaned[[sl]],
        dtype = "f32",
        fn = function(x, cl) g_ifelse(cl > 0.5, NaN, x)
      )
    })
    lazy_stack(masked) |>
      reduce_over("median", "t", nan_rm = TRUE)
  })

  out <- if (length(composites) == 1L) {
    composites[[1L]]
  } else {
    lazy_stack(composites, along = "band")
  }

  cat("graph built; planning + executing...\n")
  collect(out, path = "composite_garry.tif", nodata = -9999, distributed = TRUE)
})
cat(sprintf(
  "processing time (garry, %s, daemons %s): %.2fs\n",
  paste(bands, collapse = "+"),
  daemons_arg,
  t_all[["elapsed"]]
))
garry_daemons(0, 0)
