# The vrtility benchmark workload through garry (Phase 8c parity bench).
#
# HLS S30 over the PNG bbox, 2023, Fmask bits 0-3 masked out, warped to
# EPSG:20255 at 30 m, per-day slices, temporal median composite.
# References on this machine (vrtility/benchmarks): ODC + dask 28.35 s,
# vrtility 20.74 s (both after the STAC query, including COG write).
#
# Run: Rscript design/bench-hls-composite.R [band] [n_daemons]

suppressMessages(library(garry))

args <- commandArgs(trailingOnly = TRUE)
band <- if (length(args) >= 1) args[[1]] else "B04"
n_daemons <- if (length(args) >= 2) as.integer(args[[2]]) else 12L

# Pre-sign hrefs (one cached SAS token per collection, vrtility-style):
# per-URL GDAL signing (VSICURL_PC_URL_SIGNING) causes a signing-request
# storm across daemons and MPC 429s. Pre-signed tokens expire after ~1h,
# which is fine at benchmark timescales.
Sys.setenv(GDAL_HTTP_MULTIPLEX = "YES", GDAL_HTTP_VERSION = "2")
Sys.setenv(GDAL_HTTP_MAX_RETRY = "5", GDAL_HTTP_RETRY_DELAY = "1",
           GDAL_HTTP_RETRY_CODES = "429,500,502,503")
gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
gdalraster::set_config_option("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".tif")

bbox <- c(144.13, -7.725, 144.47, -7.475)
target <- grid_spec("EPSG:20255",
                    extent = c(183060, 9144870, 220830, 9172800),
                    dims = c((220830 - 183060) / 30,
                             (9172800 - 9144870) / 30),
                    dtype = "f32")

# --- Discovery (not timed, matching the reference benchmarks) --------------
t_query <- system.time({
  its <- stac_query(
    bbox = bbox,
    stac_source = "https://planetarycomputer.microsoft.com/api/stac/v1/",
    collection = "hls2-s30",
    start_date = "2023-01-01",
    end_date = "2023-12-31")
  its <- rstac::items_sign(its, rstac::sign_planetary_computer())
  src <- stac_sources(its, assets = c(band, "Fmask"))
  src <- stac_drop_duplicates(src)
  src <- stac_time_slices(src, "day")
})
cat(sprintf("STAC query: %.2fs; %d rows, %d slices\n",
            t_query[["elapsed"]], nrow(src),
            length(unique(src$slice))))

mirai::daemons(n_daemons)
Sys.sleep(1)

options(garry.chunk_target_px = 1.4e6)   # one chunk per slice: fewer,
                                          # bigger remote reads win here

t_all <- system.time({
  idx_band <- stac_gti_index(src, band, crs = target@crs)
  idx_mask <- stac_gti_index(src, "Fmask", crs = target@crs)
  slices <- sort(unique(src$slice))

  graph <- graph_new()
  masked <- lapply(slices, function(sl) {
    b <- lazy_source(paste0("GTI:", idx_band), graph = graph,
                     nodata = -9999,
                     open_options = c(gti_open_options(
                       target, filter = sprintf("slice = '%s'", sl),
                       sort_field = "datetime"), "NUM_THREADS=2"))
    q <- lazy_source(paste0("GTI:", idx_mask), graph = graph,
                     open_options = c(gti_open_options(
                       target, filter = sprintf("slice = '%s'", sl),
                       sort_field = "datetime"), "NUM_THREADS=2"))
    # Fmask bits 0-3 (cirrus/cloud/adjacent/shadow): any set -> nodata.
    id <- graph_add(graph, MapNode, parents = c(b@node_id, q@node_id),
                    grid = b@grid,
                    fn = function(x, f) {
                      bad <- g_bitand(g_cast(f, "i32"), 15L) > 0
                      g_ifelse(bad, NaN, x)
                    })
    LazyRaster(graph = graph, node_id = id, grid = b@grid)
  })

  comp <- reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
  outfile <- sprintf("composite_garry_%s.tif", band)
  collect(comp, path = outfile, nodata = -9999, distributed = TRUE)
})
cat(sprintf("processing time (garry, %s, %d daemons): %.2fs\n",
            band, n_daemons, t_all[["elapsed"]]))
mirai::daemons(0)
