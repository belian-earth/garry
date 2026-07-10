# SPIKE (multi-process): GDAL-direct median composite with PARALLEL warp.
#
# Same as hls-median-gdaldirect.R but the reprojection warp (the single-process
# bottleneck, ~16s) is fanned out across the daemon pool: each daemon warps one
# (slice, asset) mosaic to a flat f32 file on /dev/shm (shared by the filesystem
# namespace, no mirai serialisation). The main process then concatenates those
# f32 slices into two contiguous cubes, one raw upload each, mask + median.
#
# Fetch and warp are still separate phases here (no overlap) to isolate the warp
# parallelisation win. Workload matches GARRY_BENCH_MORPH=0 B04.
# Run: Rscript benchmarks/hls-median-gdaldirect-mp.R [n_daemons]
suppressMessages({library(garry); library(anvl); library(gdalraster); library(mirai)})
args <- commandArgs(trailingOnly = TRUE)
nd <- if (length(args) >= 1) as.integer(args[[1]]) else 16L
assets <- c("B04", "Fmask")

Sys.setenv(GDAL_HTTP_MULTIPLEX="YES", GDAL_HTTP_VERSION="2",
           GDAL_HTTP_MAX_RETRY="10", GDAL_HTTP_RETRY_DELAY="0.5",
           GDAL_HTTP_RETRY_CODES="429,500,502,503",
           GDAL_HTTP_TIMEOUT="60", GDAL_HTTP_CONNECTTIMEOUT="10",
           GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR",
           CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif",
           GDAL_INGESTED_BYTES_AT_OPEN="32768", GDAL_CACHEMAX="256",
           MALLOC_MMAP_THRESHOLD_="131072", MALLOC_TRIM_THRESHOLD_="131072")

target <- grid_spec("EPSG:20255", c(183060,9144870,220830,9172800),
                    c((220830-183060)/30, (9172800-9144870)/30), "f32")
nx <- target@dims[["x"]]; ny <- target@dims[["y"]]
gt <- target@transform; wkt <- srs_to_wkt(target@crs)
num <- function(v) sprintf("%.17g", v)
te <- c(num(target@extent[1]), num(target@extent[2]), num(target@extent[3]), num(target@extent[4]))
ts <- c(as.character(nx), as.character(ny))

its <- stac_query(bbox=c(144.13,-7.725,144.47,-7.475),
  stac_source="https://planetarycomputer.microsoft.com/api/stac/v1/",
  collection="hls2-s30", start_date="2023-01-01", end_date="2023-12-31")
its <- rstac::items_sign(its, rstac::sign_planetary_computer())
src <- stac_sources(its, assets=assets) |> stac_drop_duplicates() |> stac_time_slices("day")
slices <- sort(unique(src$slice)); Tt <- length(slices)
cat(sprintf("%d item-assets, %d day slices; grid %dx%d\n", nrow(src), Tt, nx, ny))

tmp <- file.path("/dev/shm", sprintf("gdaldirect-mp-%d", Sys.getpid())); dir.create(tmp)
on.exit(unlink(tmp, recursive=TRUE), add=TRUE)

tw <- list()
t_all <- system.time({
  ridx <- lapply(assets, function(a) stac_gti_index(src, a, crs=target@crs)); names(ridx) <- assets
  metas <- lapply(ridx, function(p) readRDS(paste0(p, ".meta.rds")))

  daemons(nd); on.exit(daemons(0), add=TRUE)
  everywhere({ suppressMessages(library(garry)); library(gdalraster)
    Sys.setenv(GDAL_HTTP_MAX_RETRY="10", GDAL_HTTP_RETRY_DELAY="0.5") })

  # ---- FETCH: all item windows -> local tmpfs, asset-parallel ----
  tw$fetch <- system.time({
    jobs <- list()
    for (a in assets) { e <- metas[[a]]$entries
      dst <- file.path(tmp, sprintf("%s_%04d.tif", a, seq_len(nrow(e))))
      for (i in seq_len(nrow(e))) jobs[[length(jobs)+1]] <-
        list(loc=e$location[i], dst=dst[i], ex=target@extent, cr=target@crs)
      metas[[a]]$entries$location <- dst }
    mirai_map(jobs, function(j) tryCatch(
        garry:::gdal_fetch_window(j$loc, j$dst, j$ex, j$cr),
        error=function(e){garry:::gdal_nodata_window(j$dst,j$ex,j$cr,255);TRUE}))[]
    lidx <- lapply(assets, function(a){p<-file.path(tmp,sprintf("%s.fgb",a))
      gti_index_create(metas[[a]]$entries, p, crs=metas[[a]]$crs); p}); names(lidx)<-assets
  })[["elapsed"]]

  # ---- ASSEMBLE: PARALLEL warp of each (slice, asset) into a DATAPOINTER
  # buffer (the proven single-process mechanic), dumped as raw f32 to a .bin
  # on shared tmpfs. Fans the ~17s single-process warp across the pool. ----
  gtstr <- paste(sprintf("%.10g", gt), collapse="/")
  sbytes <- ny*nx*4L
  f32b <- function(v) writeBin(as.numeric(v), raw(), size=4)
  tw$assemble <- system.time({
    wjobs <- list()
    for (a in assets) for (i in seq_along(slices)) wjobs[[length(wjobs)+1]] <- list(
      gti=paste0("GTI:", lidx[[a]]),
      oo=gti_open_options(target, filter=sprintf("slice = '%s'", slices[i]),
                          sort_field="datetime"),
      bin=file.path(tmp, sprintf("%s_slice_%04d.bin", a, i)),
      nd=if (a=="Fmask") "255" else "nan",
      fill=if (a=="Fmask") 255 else NaN)
    mirai_map(wjobs, function(j, .ny, .nx, .gtstr, .wkt) {
      gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")
      buf <- rep(writeBin(as.numeric(j$fill), raw(), size=4), .ny*.nx)   # prefill
      ptr <- gdalraster:::.get_data_ptr(buf)
      s <- methods::new(gdalraster::GDALRaster, j$gti, TRUE, j$oo)
      dsn <- sprintf("MEM:::DATAPOINTER=%s,PIXELS=%d,LINES=%d,BANDS=1,DATATYPE=Float32,GEOTRANSFORM=%s",
                     ptr, .nx, .ny, .gtstr)
      d <- methods::new(gdalraster::GDALRaster, dsn, FALSE); d$setProjection(.wkt)
      gdalraster::warp(s, d, "", cl_arg=c("-r","near","-dstnodata", j$nd, "-q"))
      s$close(); d$close()
      writeBin(buf, j$bin); TRUE
    }, .args=list(.ny=ny, .nx=nx, .gtstr=gtstr, .wkt=wkt))[]
  })[["elapsed"]]

  # ---- concatenate flat slices -> contiguous cube, raw upload, mask, median ----
  tw$compute <- system.time({
    cube_of <- function(a) do.call(c, lapply(seq_along(slices), function(i)
      readBin(file.path(tmp, sprintf("%s_slice_%04d.bin", a, i)), "raw", n=sbytes)))
    b04 <- garry:::g_upload_raw(cube_of("B04"), "f32", c(Tt,ny,nx))
    fm  <- garry:::g_upload_raw(cube_of("Fmask"), "f32", c(Tt,ny,nx))
    fmi     <- nv_convert(fm, "i32")
    bad     <- nv_and(fmi, nv_fill_like(fmi, 15L))
    masked  <- nv_ifelse(bad > nv_fill_like(bad, 0L), nv_fill_like(b04, NaN), b04)
    med     <- nv_median(masked, dim=1L, nan_rm=TRUE)
    m <- as_array(med)
  })[["elapsed"]]

  m[is.na(m)] <- -9999
  ds <- create("GTiff", "composite_gdaldirect_mp.tif", nx, ny, 1, "Float32", return_obj=TRUE)
  ds$setGeoTransform(gt); ds$setProjection(wkt); ds$setNoDataValue(1, -9999)
  ds$write(1, 0, 0, nx, ny, as.numeric(t(m))); ds$close()
})
cat(sprintf("\n[GDAL-direct MP] fetch=%.2fs assemble(parallel warp)=%.2fs compute=%.2fs | TOTAL=%.2fs\n",
    tw$fetch, tw$assemble, tw$compute, t_all[["elapsed"]]))
