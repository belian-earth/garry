# garry NDVI benchmark: same HLS S30 / Kuamut / 2023 / Fmask-cleanup workload as
# hls-median-composite.R, but two bands (B04, B08), a temporal median composite
# each, then NDVI = (B08 - B04) / (B08 + B04). Exercises the wired general path
# (collect() -> .gd_decompose -> .execute_gd_reduce): the two composites are the
# leaf reduces (overlap-fetched), NDVI is the upper kernel.
#
# Run:  Rscript benchmarks/ndvi-garry.R [daemons]

suppressMessages(library(garry))

args <- commandArgs(trailingOnly = TRUE)
daemons_arg <- if (length(args) >= 1) args[[1]] else "auto"
device <- Sys.getenv("GARRY_DEVICE", "cpu")

target <- grid_spec(
  "EPSG:20255",
  extent = c(183060, 9144870, 220830, 9172800),
  dims = c((220830 - 183060) / 30, (9172800 - 9144870) / 30),
  dtype = "f32"
)

t_query <- system.time({
  its <- stac_query(
    bbox = c(144.13, -7.725, 144.47, -7.475),
    stac_source = "https://planetarycomputer.microsoft.com/api/stac/v1/",
    collection = "hls2-s30",
    start_date = "2023-01-01", end_date = "2023-12-31"
  )
  its <- rstac::items_sign(its, rstac::sign_planetary_computer())
  src <- stac_sources(its, assets = c("B04", "B08", "Fmask")) |>
    stac_drop_duplicates() |>
    stac_time_slices("day")
})
cat(sprintf("STAC query: %.2fs; %d item-assets\n", t_query[["elapsed"]], nrow(src)))

if (identical(daemons_arg, "auto")) garry_daemons() else {
  np <- as.integer(strsplit(daemons_arg, "+", fixed = TRUE)[[1]])
  garry_daemons(np[[1]], np[[2]])
}
options(garry.progress = TRUE, garry.device = device)

t_all <- system.time({
  ds <- lazy_dataset(
    src, grid = target, assets = c("B04", "B08"), mask_asset = "Fmask",
    granularity = "day", sort_field = "datetime",
    nodata = c(B04 = -9999, B08 = -9999, Fmask = 255)
  )
  composite <- ds |>
    mask(from = "Fmask", where = qa_bits(0:3), open = 2L, dilate = 3L) |>
    reduce_over("median", over = "t", nan_rm = TRUE)
  composite[["ndvi"]] <- (composite[["B08"]] - composite[["B04"]]) /
                         (composite[["B08"]] + composite[["B04"]])
  cat("graph built; planning + executing...\n")
  collect(composite[["ndvi"]], path = "ndvi_garry.tif", nodata = -9999,
          distributed = TRUE)
})
cat(sprintf("processing time (garry NDVI, daemons %s): %.2fs\n",
            daemons_arg, t_all[["elapsed"]]))
garry_daemons(0, 0)
