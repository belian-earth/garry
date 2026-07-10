# SPIKE (multi-process, FUSED fetch+warp): GDAL-direct median composite with
# fetch/warp OVERLAP. One job per (slice, asset): the daemon fetches that
# slice's item windows, builds a per-slice local GTI, warps the mosaic straight
# into a DATAPOINTER buffer, and seek-writes it into a shared /dev/shm cube
# file at the slice's offset. Because each job does fetch-then-warp, warps on
# some daemons overlap fetches on others -> hides the warp behind the fetch.
# Then one raw upload per cube + mask + temporal median.
# Workload matches GARRY_BENCH_MORPH=0 B04.
# Run: Rscript benchmarks/hls-median-gdaldirect-mp2.R [n_daemons]
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
gtstr <- paste(sprintf("%.10g", gt), collapse="/")
tex <- target@extent; tcrs <- target@crs
sbytes <- ny*nx*4L

its <- stac_query(bbox=c(144.13,-7.725,144.47,-7.475),
  stac_source="https://planetarycomputer.microsoft.com/api/stac/v1/",
  collection="hls2-s30", start_date="2023-01-01", end_date="2023-12-31")
its <- rstac::items_sign(its, rstac::sign_planetary_computer())
src <- stac_sources(its, assets=assets) |> stac_drop_duplicates() |> stac_time_slices("day")
slices <- sort(unique(src$slice)); Tt <- length(slices)
cat(sprintf("%d item-assets, %d day slices; grid %dx%d\n", nrow(src), Tt, nx, ny))

tmp <- file.path("/dev/shm", sprintf("gdaldirect-mp2-%d", Sys.getpid())); dir.create(tmp)
on.exit(unlink(tmp, recursive=TRUE), add=TRUE)

t_all <- system.time({
  ridx <- lapply(assets, function(a) stac_gti_index(src, a, crs=tcrs)); names(ridx) <- assets
  metas <- lapply(ridx, function(p) readRDS(paste0(p, ".meta.rds")))

  # one job per (slice, asset): carries that slice's item rows (footprints
  # already in target CRS) + the per-slice output .bin path. (Per-slice files,
  # not one shared file: concurrent buffered writes into a shared file corrupt.)
  jobs <- list()
  for (a in assets) { e <- metas[[a]]$entries
    for (i in seq_along(slices)) { sl <- slices[i]; er <- e[e$slice == sl, , drop=FALSE]
      jobs[[length(jobs)+1]] <- list(a=a, i=i,
        bin=file.path(tmp, sprintf("%s_slice_%04d.bin", a, i)),
        locs=er$location, dt=er$datetime,
        bb=as.matrix(er[,c("xmin","ymin","xmax","ymax")]),
        nd=if (a=="Fmask") "255" else "nan", fill=if (a=="Fmask") 255 else NaN)
    } }

  daemons(nd); on.exit(daemons(0), add=TRUE)
  everywhere({ suppressMessages(library(garry)); library(gdalraster)
    Sys.setenv(GDAL_HTTP_MAX_RETRY="10", GDAL_HTTP_RETRY_DELAY="0.5")
    gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES") })

  r <- mirai_map(jobs, function(j, target, tex, tcrs, nx, ny, gtstr, wkt) {
    d <- tempfile("s"); dir.create(d)
    lf <- file.path(d, sprintf("i%02d.tif", seq_along(j$locs)))
    tf <- system.time(for (k in seq_along(j$locs)) tryCatch(
      garry:::gdal_fetch_window(j$locs[k], lf[k], tex, tcrs),
      error=function(e) garry:::gdal_nodata_window(lf[k], tex, tcrs, 255)))[["elapsed"]]
    tw <- system.time({
    ent <- data.frame(location=lf, datetime=j$dt,
                      xmin=j$bb[,1], ymin=j$bb[,2], xmax=j$bb[,3], ymax=j$bb[,4])
    fgb <- file.path(d, "s.fgb"); garry::gti_index_create(ent, fgb, crs=tcrs)
    buf <- rep(writeBin(as.numeric(j$fill), raw(), size=4), ny*nx)
    ptr <- gdalraster:::.get_data_ptr(buf)
    s <- methods::new(gdalraster::GDALRaster, paste0("GTI:", fgb), TRUE,
                      garry::gti_open_options(target, sort_field="datetime"))
    dsn <- sprintf("MEM:::DATAPOINTER=%s,PIXELS=%d,LINES=%d,BANDS=1,DATATYPE=Float32,GEOTRANSFORM=%s",
                   ptr, nx, ny, gtstr)
    o <- methods::new(gdalraster::GDALRaster, dsn, FALSE); o$setProjection(wkt)
    gdalraster::warp(s, o, "", cl_arg=c("-r","near","-dstnodata", j$nd, "-q"))
    s$close(); o$close()
    writeBin(buf, j$bin)
    unlink(d, recursive=TRUE)
    })[["elapsed"]]
    c(tf, tw)
  }, .args=list(target=target, tex=tex, tcrs=tcrs, nx=nx, ny=ny, gtstr=gtstr, wkt=wkt))[]
  cat(sprintf("[mp2] per-task sums: fetch=%.1fs warp=%.1fs\n",
              sum(vapply(r, `[`, 0, 1L)), sum(vapply(r, `[`, 0, 2L))))

  # ---- compute: concatenate per-slice bins -> cube, raw upload, mask, median ----
  cube_of <- function(a) do.call(c, lapply(seq_along(slices), function(i)
    readBin(file.path(tmp, sprintf("%s_slice_%04d.bin", a, i)), "raw", n=sbytes)))
  b04 <- garry:::g_upload_raw(cube_of("B04"), "f32", c(Tt,ny,nx))
  fm  <- garry:::g_upload_raw(cube_of("Fmask"), "f32", c(Tt,ny,nx))
  fmi     <- nv_convert(fm, "i32")
  bad     <- nv_and(fmi, nv_fill_like(fmi, 15L))
  masked  <- nv_ifelse(bad > nv_fill_like(bad, 0L), nv_fill_like(b04, NaN), b04)
  med     <- nv_median(masked, dim=1L, nan_rm=TRUE)
  m <- as_array(med)

  m[is.na(m)] <- -9999
  ds <- create("GTiff", "composite_gdaldirect_mp2.tif", nx, ny, 1, "Float32", return_obj=TRUE)
  ds$setGeoTransform(gt); ds$setProjection(wkt); ds$setNoDataValue(1, -9999)
  ds$write(1, 0, 0, nx, ny, as.numeric(t(m))); ds$close()
})
cat(sprintf("\n[GDAL-direct MP2 fused] TOTAL=%.2fs (fetch+warp overlapped)\n", t_all[["elapsed"]]))
