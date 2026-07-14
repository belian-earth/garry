# Harmonized Landsat Sentinel-2 (HLS) composite in garry.
#
# Reproduces vrtility's HLS vignette workflow: combine HLS Landsat (HLSL30) and
# HLS Sentinel-2 (HLSS30) -- which name the same physical bands differently and
# carry different band sets -- into ONE cloud-masked median composite that keeps
# every band.
#
# The whole harmonisation is two table ops:
#   1. stac_rename_assets(): map each collection's assets onto a shared schema
#      (A B G R RE1 RE2 RE3 N N2 WV C S1 S2 T1 T2 + Fmask), the union of both.
#   2. stac_merge(): concatenate the renamed tables.
# No empty-band insertion or reordering (vrtility's vrt_add_empty_band /
# vrt_move_band): lazy_dataset() gives each band only the slices that carry it,
# so a Landsat-only thermal band (T1/T2) or a Sentinel-only red-edge band
# (RE1-3, N, WV) reduces over exactly its own observations, and mask() pairs each
# band's slices with the matching Fmask slice by name.
#
# Uses the Microsoft Planetary Computer (pre-signed, no Earthdata login needed).
#
# Run:  Rscript benchmarks/hls-harmonized.R

suppressMessages(library(garry))

aoi <- c(144.13, -7.725, 144.47, -7.475)                 # lon/lat, PNG
mpc <- "https://planetarycomputer.microsoft.com/api/stac/v1/"

query <- function(collection) {
  its <- stac_query(bbox = aoi, stac_source = mpc, collection = collection,
                    start_date = "2023-01-01", end_date = "2023-12-31")
  rstac::items_sign(its, rstac::sign_planetary_computer())
}

# --- Discover + harmonise the two collections -------------------------------
l30 <- stac_sources(query("hls2-l30")) |>
  stac_filter_cloud(80) |> stac_drop_duplicates() |>
  stac_rename_assets(c(
    B01 = "A", B02 = "B", B03 = "G", B04 = "R", B05 = "N2", B06 = "S1",
    B07 = "S2", B09 = "C", B10 = "T1", B11 = "T2", Fmask = "Fmask"))

s30 <- stac_sources(query("hls2-s30")) |>
  stac_filter_cloud(80) |> stac_drop_duplicates() |>
  stac_rename_assets(c(
    B01 = "A", B02 = "B", B03 = "G", B04 = "R", B05 = "RE1", B06 = "RE2",
    B07 = "RE3", B08 = "N", B8A = "N2", B09 = "WV", B10 = "C", B11 = "S1",
    B12 = "S2", Fmask = "Fmask"))

src <- stac_merge(l30, s30)
cat(sprintf("Harmonised %d item-assets; bands: %s\n",
            nrow(src), paste(sort(unique(src$asset)), collapse = " ")))

# --- One dataset over the band union, cloud-masked, median composite --------
bands  <- c("A", "B", "G", "R", "RE1", "RE2", "RE3", "N",
            "N2", "WV", "C", "S1", "S2", "T1", "T2")
target <- grid_from_bbox(aoi, res = 30)                  # equal-area 30 m grid

garry_daemons()
options(garry.progress = TRUE)

t <- system.time({
  composite <- lazy_dataset(
    src, grid = target, assets = bands, mask_asset = "Fmask",
    nodata = c(stats::setNames(rep(-9999, length(bands)), bands), Fmask = 255)
  ) |>
    mask(from = "Fmask", where = qa_bits(0:3), open = 2, dilate = 3) |>
    reduce_over("median", over = "t")

  collect(composite, path = "hls_harmonized.tif", nodata = -9999)
})
cat(sprintf("HLS harmonized composite (%d bands): %.2fs -> hls_harmonized.tif\n",
            length(bands), t[["elapsed"]]))
garry_daemons(0, 0)
