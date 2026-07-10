# SPIKE: GDAL-direct-into-cube median composite (single-process compute).
#
# Tests the architecture we de-risked: GDAL warps f32 pixels DIRECTLY into a
# contiguous (T,ny,nx) raw cube via MEM:::DATAPOINTER,DATATYPE=Float32 (no R
# double carrier, no per-slice materialisation, no inter-stage store), then ONE
# raw upload to the device + mask + temporal median. Reads stay parallel
# (mirai fetch to tmpfs); assemble+compute is single-process.
#
# Workload matches `GARRY_BENCH_MORPH=0 hls-median-composite.R <d> B04`:
# single band B04, Fmask bits 0-3 masked, NO morphology, temporal median.
#
# Run: Rscript benchmarks/hls-median-gdaldirect.R [n_fetch_daemons]
suppressMessages({library(garry); library(anvl); library(gdalraster); library(mirai)})
args <- commandArgs(trailingOnly = TRUE)
nd <- if (length(args) >= 1) as.integer(args[[1]]) else 16L
bands <- "B04"; assets <- c("B04", "Fmask")

Sys.setenv(GDAL_HTTP_MULTIPLEX="YES", GDAL_HTTP_VERSION="2",
           GDAL_HTTP_MAX_RETRY="10", GDAL_HTTP_RETRY_DELAY="0.5",
           GDAL_HTTP_RETRY_CODES="429,500,502,503",
           GDAL_HTTP_TIMEOUT="60", GDAL_HTTP_CONNECTTIMEOUT="10",
           GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR",
           CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif",
           GDAL_INGESTED_BYTES_AT_OPEN="32768", GDAL_CACHEMAX="256",
           MALLOC_MMAP_THRESHOLD_="131072", MALLOC_TRIM_THRESHOLD_="131072")
set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")   # DATAPOINTER open gate

target <- grid_spec("EPSG:20255", c(183060,9144870,220830,9172800),
                    c((220830-183060)/30, (9172800-9144870)/30), "f32")
nx <- target@dims[["x"]]; ny <- target@dims[["y"]]

its <- stac_query(bbox=c(144.13,-7.725,144.47,-7.475),
  stac_source="https://planetarycomputer.microsoft.com/api/stac/v1/",
  collection="hls2-s30", start_date="2023-01-01", end_date="2023-12-31")
its <- rstac::items_sign(its, rstac::sign_planetary_computer())
src <- stac_sources(its, assets=assets) |> stac_drop_duplicates() |> stac_time_slices("day")
slices <- sort(unique(src$slice)); Tt <- length(slices)
cat(sprintf("%d item-assets, %d day slices; grid %dx%d\n", nrow(src), Tt, nx, ny))

tmp <- file.path("/dev/shm", sprintf("gdaldirect-%d", Sys.getpid())); dir.create(tmp)
on.exit(unlink(tmp, recursive=TRUE), add=TRUE)

# hex<->num for 48-bit addresses (exact in double)
hex2num <- function(h){h<-sub("^0x","",h);Reduce(function(a,d)a*16+d,strtoi(strsplit(h,"")[[1]],16L),0)}
num2hex <- function(n){if(n==0)return("0x0");ds<-character(0);while(n>0){r<-n%%16;ds<-c(sprintf("%x",as.integer(r)),ds);n<-(n-r)/16};paste0("0x",paste(ds,collapse=""))}
# f32 fill byte pattern (little-endian, 4 bytes)
f32_bytes <- function(v) writeBin(as.numeric(v), raw(), size = 4)

tw <- list()
t_all <- system.time({
  # remote GTI + entries per asset (discovery)
  ridx <- lapply(assets, function(a) stac_gti_index(src, a, crs=target@crs)); names(ridx) <- assets
  metas <- lapply(ridx, function(p) readRDS(paste0(p, ".meta.rds")))

  # ---- FETCH: all item windows -> local tmpfs, asset-parallel ----
  tw$fetch <- system.time({
    daemons(nd); on.exit(daemons(0), add=TRUE)
    everywhere({ suppressMessages(library(garry)); library(gdalraster)
      Sys.setenv(GDAL_HTTP_MAX_RETRY="10", GDAL_HTTP_RETRY_DELAY="0.5") })
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

  # ---- ASSEMBLE: warp each slice DIRECTLY into a contiguous f32 cube ----
  tw$assemble <- system.time({
    sb <- ny*nx*4L
    cubes <- list(B04 = rep(f32_bytes(NaN), Tt*ny*nx),      # fill NaN
                  Fmask = rep(f32_bytes(255), Tt*ny*nx))     # fill 255=bad
    base <- lapply(cubes, function(cb) hex2num(gdalraster:::.get_data_ptr(cb)))
    gt <- target@transform; wkt <- srs_to_wkt(target@crs)
    gtstr <- paste(sprintf("%.10g", gt), collapse="/")
    for (a in assets) for (ti in seq_along(slices)) {
      sl <- slices[ti]
      # GTI pinned to the target grid (the driver warps mixed-zone tiles);
      # warp then copies that target-grid output straight into our f32 buffer.
      s <- methods::new(GDALRaster, paste0("GTI:", lidx[[a]]), TRUE,
                        gti_open_options(target,
                          filter = sprintf("slice = '%s'", sl),
                          sort_field = "datetime"))
      addr <- num2hex(base[[a]] + (ti-1L)*sb)
      dsn <- sprintf("MEM:::DATAPOINTER=%s,PIXELS=%d,LINES=%d,BANDS=1,DATATYPE=Float32,GEOTRANSFORM=%s",
                     addr, nx, ny, gtstr)
      d <- methods::new(GDALRaster, dsn, FALSE); d$setProjection(wkt)
      warp(s, d, "", cl_arg=c("-r","near","-dstnodata",
           if (a=="Fmask") "255" else "nan","-q"))
      s$close(); d$close()
    }
  })[["elapsed"]]

  # ---- COMPUTE: raw f32 upload (one memcpy, no double) + mask + median ----
  # The f32 cube goes straight to the device via the patched raw path: no R
  # double carrier, no per-slice materialisation, no inter-stage store.
  tw$compute <- system.time({
    N <- Tt*ny*nx
    b04 <- garry:::g_upload_raw(cubes$B04, "f32", c(Tt,ny,nx))
    fm  <- garry:::g_upload_raw(cubes$Fmask, "f32", c(Tt,ny,nx))
    fmi     <- nv_convert(fm, "i32")
    bad     <- nv_and(fmi, nv_fill_like(fmi, 15L))          # Fmask bits 0-3
    masked  <- nv_ifelse(bad > nv_fill_like(bad, 0L),
                         nv_fill_like(b04, NaN), b04)
    med     <- nv_median(masked, dim=1L, nan_rm=TRUE)       # temporal median
    m <- as_array(med)                       # (ny, nx)
  })[["elapsed"]]

  # ---- WRITE ----
  m[is.na(m)] <- -9999
  ds <- create("GTiff", "composite_gdaldirect.tif", nx, ny, 1, "Float32", return_obj=TRUE)
  ds$setGeoTransform(gt); ds$setProjection(wkt); ds$setNoDataValue(1, -9999)
  ds$write(1, 0, 0, nx, ny, as.numeric(t(m))); ds$close()
})
cat(sprintf("\n[GDAL-direct] fetch=%.2fs assemble(warp)=%.2fs compute(upload+median)=%.2fs | TOTAL=%.2fs\n",
    tw$fetch, tw$assemble, tw$compute, t_all[["elapsed"]]))
