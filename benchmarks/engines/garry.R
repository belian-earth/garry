#!/usr/bin/env Rscript
# garry's engine: one named function per task, under the contract at the top of benchmarks/README.md.
#
#   Rscript engines/garry.R --task ID --size small|medium --variant aligned|warp|default --out DIR [--warm]
#
# Each task is the call a garry user would write: garry_daemons() defaults, no option set, no tuning. A task
# takes its parameters from spec/tasks.json and its data from the manifest, and writes one plain GeoTIFF with
# write_tif()'s defaults, which is the output spec. --arm, --chunk and --read-pool belong to the Python engines
# and are ignored here. An error ends the script with a nonzero exit: nothing here catches one.

suppressMessages(library(garry))

# -- tasks: ctx holds params, data, root, items, spec and task; path is the output ---------------------------

# HLS read through the local STAC items onto the analysis grid: one daily GTI mosaic per slice. A mask band always
# reads "near", whatever `resampling` says.
hls_dataset <- function(ctx, bands, mask_band = NULL, features = ctx$items$features) {
  d <- ctx$data
  g <- d$grid
  read <- ctx$spec$hls_read
  nodata <- stats::setNames(
    c(rep(d$nodata, length(bands)), if (!is.null(mask_band)) d$mask_nodata),
    c(bands, mask_band)
  )
  lazy_dataset(
    stac_sources(list(features = features), assets = names(nodata)),
    grid = grid_spec(g$crs, extent = c(g$xmin, g$ymin, g$xmax, g$ymax), dims = c(g$nx, g$ny)),
    assets = bands,
    mask_asset = mask_band,
    granularity = read$garry_granularity,
    nodata = nodata,
    resampling = read$resampling[["*"]]
  )
}

# Fmask bits cleared, and the mask cleaned as odc-algo does: opening(2) to despeckle, then dilation(3) as a buffer,
# disk elements. The cleaned mask is one subgraph, computed once per slice and shared by every band.
hls_masked <- function(ctx, bands) {
  mask <- ctx$spec$hls_mask
  apply_mask(
    hls_dataset(ctx, bands, mask_band = ctx$data$mask_band),
    where = qa_bits(unlist(mask$bits)),
    open = mask$open,
    dilate = mask$dilate
  )
}

# The annual files as one (t, y, x) stack. Years label the axis and become the output's band descriptions.
annual_stack <- function(ctx) {
  graph <- graph_new()
  paths <- file.path(ctx$root, vapply(ctx$data$files, `[[`, "", "path"))
  layers <- lapply(paths, lazy_source, graph = graph)
  names(layers) <- unlist(ctx$data$years)
  lazy_stack(layers, along = "t")
}

task_median <- function(ctx, path) {
  composite <- reduce_over(hls_masked(ctx, unlist(ctx$params$bands)), "median", over = "t")
  write_tif(composite, path)
}

# Two leaf reduces with band math above them: the general reduce route.
task_ndvi <- function(ctx, path) {
  red <- ctx$params$red
  nir <- ctx$params$nir
  composite <- reduce_over(hls_masked(ctx, c(red, nir)), "median", over = "t")
  ndvi <- (composite[[nir]] - composite[[red]]) / (composite[[nir]] + composite[[red]])
  write_tif(ndvi, path)
}

# A (band, t, y, x) cube reduced over t; the band axis survives. Fixed iterations against geomad's stopping rule:
# check.py records the objective gap beside the time.
task_geomedian <- function(ctx, path) {
  bands <- unlist(ctx$params$bands)
  ds <- hls_masked(ctx, bands)
  layers <- lapply(bands, function(b) ds[[b]])
  cube <- lazy_stack(stats::setNames(layers, bands), along = "band")
  write_tif(reduce_over(cube, geomedian(ctx$params$garry_iters), over = "t"), path)
}

task_ts_hampel <- function(ctx, path) {
  p <- ctx$params
  write_tif(hampel_smooth(annual_stack(ctx), k = p$k, t0 = p$t0), path)
}

# The plain smoother: the old benchmark's robust passes have no counterpart in the comparator.
task_ts_kalman <- function(ctx, path) {
  p <- ctx$params
  body <- kalman_llt(p$sigma_lvl, p$sigma_slp, p$sigma_obs, output = p$output)
  write_tif(scan_over(annual_stack(ctx), body, over = "t", direction = "bidir"), path)
}

# Mean of the valid cells in the window. Cells beyond the raster edge arrive as NaN, so the edge needs no case.
window_nanmean <- function(shifted) {
  total <- 0
  valid <- 0
  for (v in shifted) {
    ok <- !g_is_nodata(v)
    total <- total + g_ifelse(ok, v, 0)
    valid <- valid + g_ifelse(ok, 1, 0)
  }
  total / valid
}

# One slice is one item, read through the STAC reader as the other engines read it. `t` counts from 0, as `item_t`.
task_focal <- function(ctx, path) {
  p <- ctx$params
  item <- ctx$items$features[which(unlist(ctx$data$item_t) == p$t)]
  x <- hls_dataset(ctx, p$band, features = item)[[p$band]]
  write_tif(focal_map(x, window_nanmean, radius = p$radius), path)
}

# The file form builds one source per band, and the bands fan out across the read pool.
task_wide_write <- function(ctx, path) {
  out <- ctx$task$output
  source <- file.path(ctx$root, ctx$data$files[[1L]]$path)
  write_tif(lazy_dataset(source), path, dtype = sub("^int", "i", out$dtype), nodata = out$nodata)
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
      stop(glue::glue("garry.R: bad argument {key}"), call. = FALSE)
    }
  }
  missing <- setdiff(c("task", "size", "variant", "out"), names(args))
  if (length(missing)) {
    stop(glue::glue("garry.R: needs --{missing[[1L]]}"), call. = FALSE)
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

# Which garry ran: the version does not change between builds, and the repository's commit need not be installed.
garry_build <- function() {
  path <- find.package("garry")
  sums <- tools::md5sum(file.path(path, c("R/garry.rdb", "libs/garry.so")))
  list(
    library = dirname(path),
    built = utils::packageDescription("garry")$Built,
    hash = paste(substr(unname(sums), 1L, 8L), collapse = "-")
  )
}

environment_record <- function(pools) {
  version <- function(pkg) as.character(utils::packageVersion(pkg))
  list(
    phase = "env",
    r = as.character(getRversion()),
    garry = version("garry"),
    build = garry_build(),
    anvl = version("anvl"),
    pjrt = version("pjrt"),
    gdalraster = version("gdalraster"),
    gdal = gdalraster::gdal_version()[[1L]],
    proj = gdalraster::proj_version()$name,
    cores = parallel::detectCores(),
    read_daemons = pools$read,
    compute_daemons = pools$compute,
    gdal_cachemax_mb = garry_opt("gdal_cachemax_mb"),
    pool_affinity = garry_opt("pool_affinity"),
    device = garry_opt("device")
  )
}

main <- function() {
  args <- parse_args(commandArgs(trailingOnly = TRUE))
  root <- Sys.getenv("GARRY_BENCH_DATA")
  if (!nzchar(root)) {
    stop("garry.R: set GARRY_BENCH_DATA", call. = FALSE)
  }
  spec <- jsonlite::read_json(file.path(dirname(script_dir()), "spec", "tasks.json"))
  task <- Filter(function(t) t$id == args$task, spec$tasks)
  if (!length(task)) {
    stop(glue::glue("garry.R: no task {args$task}"), call. = FALSE)
  }
  task <- task[[1L]]
  manifest <- jsonlite::read_json(file.path(root, args$size, "manifest.json"))
  dataset <- if (task$data == "hls") paste0("hls-", args$variant) else task$data
  data <- manifest$datasets[[dataset]]
  ctx <- list(
    params = task$params,
    task = task,
    spec = spec,
    data = data,
    dataset = dataset,
    root = manifest$root,
    items = if (!is.null(data$items)) jsonlite::read_json(file.path(manifest$root, data$items))
  )
  run <- get(paste0("task_", task$id), mode = "function")

  pools <- garry_daemons()
  on.exit(garry_daemons(0, 0), add = TRUE)
  startup_s <- proc.time()[["elapsed"]]
  emit(environment_record(pools))

  phases <- if (args$warm) c("cold", "warm") else "cold"
  for (phase in phases) {
    start <- proc.time()[["elapsed"]]
    run(ctx, file.path(args$out, paste0(phase, ".tif")))
    emit(list(
      phase = phase,
      wall_s = round(proc.time()[["elapsed"]] - start, 3),
      startup_s = startup_s,
      route = garry_last_route()
    ))
  }
}

main()
