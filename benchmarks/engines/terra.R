#!/usr/bin/env Rscript
# terra's engine: one named function per task, under the contract at the top of benchmarks/README.md.
#
#   Rscript engines/terra.R --task ID --size small|medium --variant aligned|warp|default --out DIR [--warm]
#
# Each task is what an expert terra user would write: terra's own API and its C++ paths wherever they exist. Imports
# are terra, jsonlite and base R; the only parallelism is what terra offers: TBB in focal(), GDAL threads in reads,
# project() and writes, and tile_apply() across BENCH_THREADS workers for R code. Each phase starts its workers before
# its clock, as the contract asks: tile_apply() would otherwise spend about 40 s of it on 20 of them. They stop after
# it, because terra's C++ memory stays in a worker that lived through a phase, and a warm phase would start with that.
# An error ends the script with a nonzero exit: nothing here catches one.

suppressMessages(library(terra))

MEM_SHARE <- 0.75 # of the size's cap: terra plans from system RAM, not the cgroup, so memmax tells it the truth
WORKER_BASE_GB <- 0.12 # one idle R worker with terra loaded
TILE_COPIES <- 4L # of a tile's layers, what the R code in a worker holds at its peak
KALMAN_KAPPA <- 1e7 # garry's .kalman_kappa: a diffuse start
TILED_TASKS <- c("ts_hampel", "ts_kalman") # what runs R code on workers

# -- reads ---------------------------------------------------------------------------------------------------

grid_template <- function(ctx) {
  g <- ctx$data$grid
  rast(nrows = g$ny, ncols = g$nx, xmin = g$xmin, xmax = g$xmax, ymin = g$ymin, ymax = g$ymax, crs = g$crs)
}

item_paths <- function(ctx, band, ids) {
  file.path(ctx$root, ctx$dataset, ids, paste0(ids, ".", band, ".tif"))
}

# One multi-band VRT over files. Its bands are dates, so each keeps its own nodata.
vrt_stack <- function(ctx, paths) {
  vrt_path <- tempfile(tmpdir = ctx$tempdir, fileext = ".vrt")
  vrt(paths, filename = vrt_path, options = "-separate", overwrite = TRUE)
}

# Items of a band onto the grid. A multi-band VRT warps as one GDAL call, one transformer for all its dates, where a
# call per file builds one each.
warp_items <- function(ctx, band, ids, method) {
  stack <- vrt_stack(ctx, item_paths(ctx, band, ids))
  project(stack, grid_template(ctx), method = method, threads = TRUE, warpOpts = "UNIFIED_SRC_NODATA=NO")
}

# One band as layers on the analysis grid. Aligned files are that grid, in time order; item_t counts from 0. On warp a
# date both zones hold is a mosaic, the later item on top and its nodata transparent: within a day items sort by zone,
# as garry's GTI sorts them by datetime, so T55 is on top of T54. Dates one zone holds warp apart, so cover() needs no
# subset. Those layers are not in time order, but every band and the mask share the order and no output has a time axis.
hls_stack <- function(ctx, band, method) {
  d <- ctx$data
  ids <- unlist(d$ids)
  t <- unlist(d$item_t)
  if (ctx$variant == "aligned") {
    return(vrt_stack(ctx, item_paths(ctx, band, ids[order(t)])))
  }
  zone <- sub("^HLS\\.S30\\.(T[0-9]+)\\..*$", "\\1", ids)
  zones <- sort(unique(zone))
  stopifnot(length(zones) == 2L)
  both <- t %in% Reduce(intersect, split(t, zone))
  warped <- function(items) {
    i <- which(items)
    warp_items(ctx, band, ids[i[order(t[i])]], method)
  }
  stack <- c(
    warped(zone == zones[[1L]] & !both),
    warped(zone == zones[[2L]] & !both),
    cover(warped(zone == zones[[2L]] & both), warped(zone == zones[[1L]] & both))
  )
  gc(FALSE) # terra's cells are C++ memory, which R's collector cannot see filling up
  stack
}

# A disk as a focal window: NA leaves a cell out.
disk <- function(r) {
  span <- (-r):r
  inside <- outer(span, span, function(a, b) a^2 + b^2 <= r^2)
  inside[] <- ifelse(inside, 1, NA_real_)
  inside
}

# Bits 0-3 of Fmask flag a pixel, then an opening despeckles and a dilation buffers, disk elements, as on the other
# arms. Fmask nodata reads as clear, and so does everything beyond the raster: that is fillvalue. Terra has no bit
# operators, so a table over every code does the bit test. Terra's "near" is the spec's "nearest". A disk's sum counts
# the flagged cells under it: erosion wants all of them and dilation any. gc() follows each step, because terra's cells
# are C++ memory, which R's collector cannot see filling up.
clean_mask <- function(ctx) {
  m <- ctx$spec$hls_mask
  bits <- Reduce(bitwOr, bitwShiftL(1L, unlist(m$bits)))
  codes <- seq(0L, ctx$data$mask_nodata - 1L)
  table <- cbind(c(codes, NA), c(bitwAnd(codes, bits) > 0L, 0))
  flagged_under <- function(x, r) focal(x, w = disk(r), fun = "sum", fillvalue = 0)
  flagged <- classify(hls_stack(ctx, ctx$data$mask_band, "near"), table)
  eroded <- flagged_under(flagged, m$open) == sum(!is.na(disk(m$open)))
  rm(flagged)
  gc(FALSE)
  opened <- flagged_under(eroded, m$open) > 0
  rm(eroded)
  gc(FALSE)
  clean <- flagged_under(opened, m$dilate) > 0
  rm(opened)
  gc(FALSE)
  clean
}

masked_median <- function(ctx, band, clean) {
  stack <- hls_stack(ctx, band, ctx$spec$hls_read$resampling[["*"]])
  composite <- median(mask(stack, clean, maskvalues = 1), na.rm = TRUE)
  gc(FALSE)
  composite
}

annual_stack <- function(ctx) {
  rast(file.path(ctx$root, vapply(ctx$data$files, `[[`, "", "path")))
}

# What runs on a worker. tile_apply() serialises a function with its environment, unless that is the global one, so
# what a tile needs lives in this one environment, and a worker needs no copy of this script.
kit <- local({
  # Local linear trend, smoothed level, garry's kalman_llt(): the filter, then the cancellation-free RTS gain, on whole
  # columns. A missing year has gain 0, so the update leaves the prediction. Fewer than three observations is NaN. A
  # block is vector arithmetic on whole columns, so app() must not take this for a per-cell function: a vector stops it.
  kalman_block <- function(y, q_lvl, q_slp, h, kappa) {
    stopifnot(is.matrix(y))
    n <- nrow(y)
    years <- ncol(y)
    a1 <- a2 <- P12 <- numeric(n)
    P11 <- P22 <- rep(kappa, n)
    filtered <- array(0, c(n, years, 5L))
    for (t in seq_len(years)) {
      P11p <- P11 + 2 * P12 + P22 + q_lvl
      P12p <- P12 + P22
      P22p <- P22 + q_slp
      a1p <- a1 + a2
      seen <- !is.na(y[, t])
      v <- y[, t] - a1p
      v[!seen] <- 0
      Fv <- P11p + h
      K1 <- seen * P11p / Fv
      K2 <- seen * P12p / Fv
      a1 <- a1p + K1 * v
      a2 <- a2 + K2 * v
      P11 <- (1 - K1) * P11p
      P12 <- (1 - K1) * P12p
      P22 <- P22p - K2 * P12p
      filtered[, t, ] <- c(a1, a2, P11, P12, P22)
    }
    out <- matrix(NaN, n, years)
    out[, years] <- a1
    a1s <- a1
    a2s <- a2
    for (t in rev(seq_len(years - 1L))) {
      f <- filtered[, t, , drop = FALSE]
      P11p <- f[, , 3L] + 2 * f[, , 4L] + f[, , 5L] + q_lvl
      P12p <- f[, , 4L] + f[, , 5L]
      P22p <- f[, , 5L] + q_slp
      det <- P11p * P22p - P12p^2
      M11 <- 1 - q_lvl * P22p / det
      M12 <- q_lvl * P12p / det
      M21 <- q_slp * P12p / det
      M22 <- 1 - q_slp * P11p / det
      d1 <- a1s - (f[, , 1L] + f[, , 2L])
      d2 <- a2s - f[, , 2L]
      a1s <- f[, , 1L] + (M11 - M21) * d1 + (M12 - M22) * d2
      a2s <- f[, , 2L] + M21 * d1 + M22 * d2
      out[, t] <- a1s
    }
    out[rowSums(!is.na(y)) < 3L, ] <- NaN
    out
  }

  # No callback: the window's median and scaled MAD are terra's median() over layers, one output year at a time. The
  # window shrinks at the series ends, median() skips NaN, and a gap stays a gap. The tile comes into memory first,
  # because every call below would otherwise go back to the files.
  hampel <- function(x, k, t0) {
    x <- toMemory(x)
    years <- nlyr(x)
    filtered <- lapply(seq_len(years), function(t) {
      window <- x[[max(1L, t - k):min(years, t + k)]]
      y <- x[[t]]
      med <- median(window, na.rm = TRUE)
      mad <- median(abs(window - med), na.rm = TRUE) * 1.4826
      mask(ifel(abs(y - med) <= t0 * mad, y, med), y)
    })
    rast(filtered)
  }

  block_app <- function(x, block, ...) {
    app(x, block, ...)
  }

  # One worker's share of what the run has, then `work` on its tile. A worker takes one thread: the others are the
  # other workers.
  tile_worker <- function(x, work, args, gb, cache_mb, tempdir) {
    gc(FALSE) # the last tile's rasters: their cells are C++ memory, which R's collector cannot see filling up
    terraOptions(memmax = gb, memfrac = 0.9, tempdir = tempdir, threads = 1, progress = 0)
    setGDALconfig("GDAL_NUM_THREADS", "1")
    gdalCache(cache_mb)
    do.call(work, c(list(x), args))
  }

  environment()
})

# -- output --------------------------------------------------------------------------------------------------

# The output spec, with a task's own block over it, as writeRaster options. Compression threads follow
# GDAL_NUM_THREADS, in whichever process writes.
write_options <- function(ctx) {
  out <- utils::modifyList(ctx$spec$output, as.list(ctx$task$output))
  types <- c(float32 = "FLT4S", int8 = "INT1S")
  size <- out$blocksize
  list(
    datatype = types[[out$dtype]],
    NAflag = if (identical(out$nodata, "nan")) NaN else out$nodata,
    gdal = c(
      paste0("COMPRESS=", toupper(out$compress)),
      "TILED=YES",
      paste0("BLOCKXSIZE=", size),
      paste0("BLOCKYSIZE=", size),
      paste0("INTERLEAVE=", toupper(out$interleave)),
      paste0("BIGTIFF=", toupper(out$bigtiff))
    )
  )
}

write_tif <- function(ctx, x, path) {
  writeRaster(x, path, overwrite = TRUE, wopt = write_options(ctx))
  invisible(path)
}

# -- tiles ---------------------------------------------------------------------------------------------------

# Tiles a worker can hold, at least two per worker. tile_apply() would size them from system RAM, which is not what
# this run has.
tile_extents <- function(ctx, x) {
  grid <- grid_template(ctx)
  by_memory <- sqrt((ctx$worker_gb - WORKER_BASE_GB) * 1024^3 / (TILE_COPIES * 8 * nlyr(x)))
  by_workers <- sqrt(ncell(grid) / (2 * ctx$threads))
  side <- min(nrow(grid), ncol(grid), ceiling(min(by_memory, by_workers)))
  getTileExtents(grid, side)
}

# R code over file-backed x across BENCH_THREADS workers, one output. todisk stays on through the call because
# tile_apply() otherwise wrap()s a raster that fits in memory with all its cells and ships them to every worker: with
# it the workers get file names, and each reads its own window.
on_tiles <- function(ctx, x, path, work, args) {
  terraOptions(todisk = TRUE)
  on.exit(terraOptions(todisk = FALSE))
  tile_apply(
    x,
    kit$tile_worker,
    cores = ctx$cluster,
    tiles = tile_extents(ctx, x),
    work = work,
    args = args,
    gb = ctx$worker_gb,
    cache_mb = ctx$worker_cache_mb,
    tempdir = ctx$tempdir,
    filename = path,
    overwrite = TRUE,
    wopt = write_options(ctx)
  )
  invisible(path)
}

# -- tasks: ctx holds params, data, root, spec and task; path is the output --------------------------------------

task_median <- function(ctx, path) {
  clean <- clean_mask(ctx)
  write_tif(ctx, rast(lapply(unlist(ctx$params$bands), masked_median, ctx = ctx, clean = clean)), path)
}

task_ndvi <- function(ctx, path) {
  clean <- clean_mask(ctx)
  red <- masked_median(ctx, ctx$params$red, clean)
  nir <- masked_median(ctx, ctx$params$nir, clean)
  write_tif(ctx, (nir - red) / (nir + red), path)
}

task_ts_hampel <- function(ctx, path) {
  on_tiles(ctx, annual_stack(ctx), path, kit$hampel, list(k = ctx$params$k, t0 = ctx$params$t0))
}

task_ts_kalman <- function(ctx, path) {
  p <- ctx$params
  noise <- list(q_lvl = p$sigma_lvl^2, q_slp = p$sigma_slp^2, h = p$sigma_obs^2, kappa = KALMAN_KAPPA)
  on_tiles(ctx, annual_stack(ctx), path, kit$block_app, c(list(block = kit$kalman_block), noise))
}

# One slice is one item. TBB runs the window: na.rm takes the mean of its valid cells, none beyond the raster.
task_focal <- function(ctx, path) {
  p <- ctx$params
  id <- unlist(ctx$data$ids)[match(p$t, unlist(ctx$data$item_t))]
  x <- rast(item_paths(ctx, p$band, id))
  write_tif(ctx, focal(x, w = 2L * p$radius + 1L, fun = "mean", na.rm = TRUE), path)
}

task_wide_write <- function(ctx, path) {
  write_tif(ctx, rast(file.path(ctx$root, ctx$data$files[[1L]]$path)), path)
}

# -- harness -------------------------------------------------------------------------------------------------

parse_args <- function(argv) {
  valued <- c("--task", "--size", "--variant", "--out", "--arm", "--chunk", "--read-pool")
  args <- list(warm = FALSE)
  i <- 1L
  while (i <= length(argv)) {
    key <- argv[[i]]
    if (key == "--warm") {
      args$warm <- TRUE
      i <- i + 1L
    } else if (key %in% valued && i < length(argv)) {
      args[[sub("^--", "", key)]] <- argv[[i + 1L]]
      i <- i + 2L
    } else {
      stop(paste("terra.R: bad argument", key), call. = FALSE)
    }
  }
  missing <- setdiff(c("task", "size", "variant", "out"), names(args))
  if (length(missing)) {
    stop(paste0("terra.R: needs --", missing[[1L]]), call. = FALSE)
  }
  args
}

script_dir <- function() {
  file <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
  dirname(normalizePath(file))
}

emit <- function(record) {
  cat(jsonlite::toJSON(record, auto_unbox = TRUE, digits = NA, null = "null"), "\n", sep = "")
  flush(stdout())
}

environment_record <- function(ctx) {
  lib <- find.package("terra")
  versions <- libVersion("all")
  options <- terraOptions(print = FALSE)
  list(
    phase = "env",
    r = as.character(getRversion()),
    terra = as.character(utils::packageVersion("terra")),
    build = list(
      library = dirname(lib),
      built = utils::packageDescription("terra")$Built,
      hash = substr(unname(tools::md5sum(file.path(lib, "libs", "terra.so"))), 1L, 8L)
    ),
    gdal = versions$gdal,
    proj = versions$proj,
    geos = versions$geos,
    tbb = isTRUE(versions$TBB),
    bench_threads = ctx$threads,
    gdal_num_threads = Sys.getenv("GDAL_NUM_THREADS"),
    gdal_cachemax_mb = gdalCache(),
    terra_memmax_gb = options$memmax,
    terra_memfrac = options$memfrac,
    terra_threads = options$threads,
    terra_parallel = options$parallel,
    worker_gb = ctx$worker_gb,
    worker_cache_mb = ctx$worker_cache_mb
  )
}

main <- function() {
  args <- parse_args(commandArgs(trailingOnly = TRUE))
  root <- Sys.getenv("GARRY_BENCH_DATA")
  threads <- as.integer(Sys.getenv("BENCH_THREADS"))
  tempdir_ <- Sys.getenv("TMPDIR")
  if (!nzchar(root) || is.na(threads) || !nzchar(tempdir_)) {
    stop("terra.R: set GARRY_BENCH_DATA, BENCH_THREADS and TMPDIR", call. = FALSE)
  }
  spec_dir <- file.path(dirname(script_dir()), "spec")
  spec <- jsonlite::read_json(file.path(spec_dir, "tasks.json"))
  data_spec <- jsonlite::read_json(file.path(spec_dir, "data.json"))
  task <- Filter(function(t) t$id == args$task, spec$tasks)
  if (!length(task)) {
    stop(paste("terra.R: no task", args$task), call. = FALSE)
  }
  task <- task[[1L]]
  manifest <- jsonlite::read_json(file.path(root, args$size, "manifest.json"))
  dataset <- if (task$data == "hls") paste0("hls-", args$variant) else task$data
  mem_gb <- MEM_SHARE * as.numeric(sub("G$", "", data_spec$sizes[[args$size]]$cap))
  cache_mb <- as.numeric(spec$arms[["odc-dask"]]$env$GDAL_CACHEMAX) # one number across the comparators
  ctx <- list(
    params = task$params,
    task = task,
    spec = spec,
    data = manifest$datasets[[dataset]],
    dataset = dataset,
    variant = args$variant,
    root = manifest$root,
    threads = threads,
    tempdir = tempdir_,
    worker_gb = mem_gb / threads,
    worker_cache_mb = cache_mb / threads
  )
  Sys.setenv(GDAL_NUM_THREADS = threads)
  gdalCache(cache_mb)
  terraOptions(memmax = mem_gb, memfrac = 0.9, tempdir = tempdir_, threads = threads, parallel = TRUE, progress = 0)

  run <- get(paste0("task_", task$id), mode = "function")
  startup_s <- proc.time()[["elapsed"]]
  emit(environment_record(ctx))
  phases <- if (args$warm) c("cold", "warm") else "cold"
  for (phase in phases) {
    if (task$id %in% TILED_TASKS) {
      ctx$cluster <- parallel::makeCluster(threads)
      parallel::clusterEvalQ(ctx$cluster, suppressMessages(library(terra)))
    }
    start <- proc.time()[["elapsed"]]
    run(ctx, file.path(args$out, paste0(phase, ".tif")))
    wall_s <- round(proc.time()[["elapsed"]] - start, 3)
    emit(list(phase = phase, wall_s = wall_s, startup_s = startup_s))
    if (task$id %in% TILED_TASKS) {
      parallel::stopCluster(ctx$cluster)
    }
    tmpFiles(current = TRUE, remove = TRUE)
    gc(FALSE)
  }
}

if (sys.nframe() == 0L) main()
