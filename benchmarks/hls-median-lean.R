# LEAN executor spike (read-path investigation): fetch all item windows
# local -> local GTI per asset -> tile the analysis grid (halo-expanded)
# -> mirai-map execute_plan per tile (no inter-stage store) -> assemble.
# Same HLS median+morphology workload as hls-median-composite.R; this
# swaps the staged distributed scheduler for a chunk-parallel map that
# reuses execute_plan wholesale. Args: [n_daemons] [bands...]
suppressMessages({library(garry); library(anvl); library(gdalraster); library(mirai)})
args <- commandArgs(trailingOnly = TRUE)
nd_arg <- if (length(args) >= 1) as.integer(args[[1]]) else 12L
bands  <- if (length(args) >= 2) args[-1] else c("B04","B03","B02")

Sys.setenv(GDAL_HTTP_MULTIPLEX="YES", GDAL_HTTP_VERSION="2",
           GDAL_HTTP_MAX_RETRY="10", GDAL_HTTP_RETRY_DELAY="0.5",
           GDAL_HTTP_RETRY_CODES="429,500,502,503",
           GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR",
           CPL_VSIL_CURL_ALLOWED_EXTENSIONS=".tif",
           GDAL_INGESTED_BYTES_AT_OPEN="32768", GDAL_CACHEMAX="256",
           MALLOC_MMAP_THRESHOLD_="131072", MALLOC_TRIM_THRESHOLD_="131072")

target <- grid_spec("EPSG:20255", c(183060,9144870,220830,9172800),
                    c((220830-183060)/30, (9172800-9144870)/30), "f32")
morph <- !identical(Sys.getenv("GARRY_BENCH_MORPH"), "0")
H <- if (morph) 7L else 0L                       # opening(2)+dilation(3) halo

its <- stac_query(bbox=c(144.13,-7.725,144.47,-7.475),
  stac_source="https://planetarycomputer.microsoft.com/api/stac/v1/",
  collection="hls2-s30", start_date="2023-01-01", end_date="2023-12-31")
its <- rstac::items_sign(its, rstac::sign_planetary_computer())
src <- stac_sources(its, assets=c(bands,"Fmask")) |> stac_drop_duplicates() |> stac_time_slices("day")
slices <- sort(unique(src$slice))
assets <- c(bands, "Fmask")
tmp <- file.path("/dev/shm", sprintf("lean-%d", Sys.getpid())); dir.create(tmp)
on.exit(unlink(tmp, recursive=TRUE), add=TRUE)

t_all <- system.time({
  # remote GTI + meta per asset (not timed heavily; discovery)
  ridx <- lapply(assets, function(a) stac_gti_index(src, a, crs=target@crs))
  names(ridx) <- assets
  metas <- lapply(ridx, function(p) readRDS(paste0(p, ".meta.rds")))

  # ---- FETCH: all item windows -> local tmpfs, asset-parallel ----
  daemons(nd_arg); on.exit(daemons(0), add=TRUE)
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
      error=function(e) { garry:::gdal_nodata_window(j$dst, j$ex, j$cr, 255); TRUE }))[]

  # ---- local GTI per asset (rewritten locations) ----
  lidx <- lapply(assets, function(a) { p <- file.path(tmp, sprintf("%s.fgb", a))
    gti_index_create(metas[[a]]$entries, p, crs=metas[[a]]$crs); p })
  names(lidx) <- assets

  # ---- tiles over the analysis grid (halo-expanded) ----
  nx <- target@dims[["x"]]; ny <- target@dims[["y"]]; res <- target@transform[2]
  ex0 <- target@extent; step <- as.integer(Sys.getenv("GARRY_LEAN_STEP", "512"))
  tiles <- list()
  for (ox in seq(0L, nx-1L, by=step)) for (oy in seq(0L, ny-1L, by=step)) {
    x0<-max(0L,ox-H); y0<-max(0L,oy-H); x1<-min(nx,ox+step+H); y1<-min(ny,oy+step+H)
    tiles[[length(tiles)+1]] <- list(ox=ox,oy=oy,
      w=min(step,nx-ox), h=min(step,ny-oy),
      x0=x0,y0=y0,we=x1-x0,he=y1-y0)
  }

  # ---- per-tile: build pipeline pinned to expanded extent, execute_plan ----
  res_tiles <- mirai_map(tiles, function(tl) {
    te <- c(ex0[1]+tl$x0*res, ex0[4]-(tl$y0+tl$he)*res,
            ex0[1]+(tl$x0+tl$we)*res, ex0[4]-tl$y0*res)
    g <- grid_spec("EPSG:20255", te, c(tl$we, tl$he), "f32")
    dsk<-function(r){o<-expand.grid(dx=-r:r,dy=-r:r);which(o$dx^2+o$dy^2<=r^2)}
    ero<-function(x,r){s<-dsk(r);focal(x,radius=as.integer(r),fn=function(sh)Reduce(`*`,sh[s]))}
    dil<-function(x,r){s<-dsk(r);focal(x,radius=as.integer(r),fn=function(sh)1-Reduce(`*`,lapply(sh[s],function(z)1-z)))}
    G <- graph_new()
    sof<-function(a,sl,nd) lazy_source(paste0("GTI:",lidx[[a]]), graph=G, nodata=nd,
      grid=g, open_options=gti_open_options(g, filter=sprintf("slice = '%s'",sl), sort_field="datetime"))
    bad_of<-function(sl){ bad<-lazy_map(sof("Fmask",sl,255),dtype="f32",fn=function(f){
        fc<-g_ifelse(g_is_nodata(f),0,f);g_cast(g_bitand(g_cast(fc,"i32"),15L)>0,"f32")})
      if(!morph) return(bad); bad|>ero(2)|>dil(2)|>dil(3) }
    cleaned<-lapply(slices,bad_of); names(cleaned)<-slices
    comps<-lapply(bands,function(b){ masked<-lapply(slices,function(sl)
        lazy_map(sof(b,sl,-9999),cleaned[[sl]],dtype="f32",fn=function(x,cl)g_ifelse(cl>0.5,NaN,x)))
      reduce_over(lazy_stack(masked),"median","t",nan_rm=TRUE) })
    out <- if(length(comps)==1) comps[[1]] else lazy_stack(comps,along="band")
    r <- execute_plan(plan_lazy(out))                # (band,he,we) or (he,we)
    if (length(dim(r))==2) r <- array(r, c(1,dim(r)))
    cx<-tl$ox-tl$x0; cy<-tl$oy-tl$y0
    list(tl=tl, core=r[,(cy+1):(cy+tl$h),(cx+1):(cx+tl$w),drop=FALSE])
  }, lidx=lidx, slices=slices, bands=bands, morph=morph, ex0=ex0, res=res)[]

  # ---- assemble + write ----
  nb <- length(bands)
  full <- array(-9999, c(nb, ny, nx))
  for (rt in res_tiles) { tl<-rt$tl
    full[,(tl$oy+1):(tl$oy+tl$h),(tl$ox+1):(tl$ox+tl$w)] <- rt$core }
  ds <- create("GTiff", "composite_lean.tif", nx, ny, nb, "Float32", return_obj=TRUE)
  ds$setGeoTransform(target@transform); ds$setProjection(gdalraster::srs_to_wkt(target@crs))
  for (b in seq_len(nb)) { ds$setNoDataValue(b, -9999)
    m <- full[b,,]; m[is.na(m)] <- -9999; ds$write(b,0,0,nx,ny,as.numeric(t(m))) }
  ds$close()
})
cat(sprintf("processing time (garry LEAN, %s, %d daemons): %.2fs\n",
    paste(bands,collapse="+"), nd_arg, t_all[["elapsed"]]))
