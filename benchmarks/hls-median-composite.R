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
# the mask cleanup. GARRY_BENCH_ENGINE=cptkirk reads via lazy_cog (cptkirk)
# instead of lazy_dataset (GDAL) -- same composite, different read engine.
# e.g.  Rscript benchmarks/hls-median-composite.R auto B04 B03 B02
#       GARRY_BENCH_ENGINE=cptkirk Rscript benchmarks/hls-median-composite.R
#
# For a back-to-back garry-vs-ODC run (timings + a band-by-band output check),
# use benchmarks/compare.sh (REPS=3 benchmarks/compare.sh).

suppressMessages(library(garry))

args <- commandArgs(trailingOnly = TRUE)
daemons_arg <- if (length(args) >= 1) args[[1]] else "auto"
bands <- if (length(args) >= 2) args[-1] else c("B04", "B03", "B02")
device <- Sys.getenv("GARRY_DEVICE", "cpu") # "cpu" or "cuda" (GPU compute)
# Read engine: "gdal" -> lazy_dataset (GTI + GDAL warp-on-read, the default);
# "cptkirk" -> lazy_cog (same dataset, read through cptkirk). HLS assets are
# single-band-per-file, so cptkirk has no intra-file band concurrency to exploit
# here -- this branch measures exactly that (the routing thesis: cptkirk earns
# its place on multi-band files, not single-band time series).
engine <- Sys.getenv("GARRY_BENCH_ENGINE", "gdal")

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
  its <- stac_sign_mpc(its) # collection-level token cache (memory + disk)

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
  # One lazy dataset: a band per asset plus the Fmask QA band, each a
  # per-day GTI mosaic pinned to the target grid (mixed UTM zones warp
  # per tile), all on one shared IR graph. Value bands read -9999 -> NaN,
  # Fmask reads 255 -> NaN. lazy_dataset() does the per-asset GTI index +
  # single metadata probe that the manual scaffolding used to.
  reader <- if (identical(engine, "cptkirk")) lazy_cog else lazy_dataset
  ds <- reader(
    src,
    grid = target,
    assets = bands,
    mask_asset = "Fmask",
    granularity = "day",
    sort_field = "datetime",
    nodata = c(stats::setNames(rep(-9999, length(bands)), bands), Fmask = 255)
  )

  # mask() derives the bad-pixel mask from Fmask (bits 0-3: cirrus /
  # cloud / adjacent / shadow), cleans it with odc-algo morphology
  # (opening(2) despeckle then dilation(3) buffer, disk elements),
  # applies it to every value band, and drops Fmask. The cleaned mask is
  # one shared subgraph computed once per slice and dedup'd across bands
  # (D11 fuses the morphology); reduce_over collapses time per band; then
  # collect() assembles the band axis and plans the whole dataset in one
  # scheduler pass, keeping the network saturated end to end. NaN (Fmask
  # fill and beyond-edge halo pad) reads as clear, matching scipy's
  # constant-0 border.
  morph <- !identical(Sys.getenv("GARRY_BENCH_MORPH"), "0")
  composite <- ds |>
    mask(
      from = "Fmask",
      where = qa_bits(0:3),
      open = if (morph) 2L else 0L,
      dilate = if (morph) 3L else 0L
    ) |>
    reduce_over("median", over = "t", nan_rm = TRUE)

  cat("graph built; planning + executing...\n")
  collect(
    composite,
    path = "composite_garry.tif",
    nodata = -9999
  )
})
cat(sprintf(
  "processing time (garry, %s engine, %s, daemons %s): %.2fs\n",
  engine,
  paste(bands, collapse = "+"),
  daemons_arg,
  t_all[["elapsed"]]
))
garry_daemons(0, 0)
