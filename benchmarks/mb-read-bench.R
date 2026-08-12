# Isolated multi-band COG read experiments: GDAL levers vs cptkirk.
#
# Workload: one 2048x2048 native-pixel window, all 64 Int8 bands, of a public
# AEF annual embedding tile (COG, ZSTD, INTERLEAVE=BAND, 1024px tiles). The
# worst case for stock GDAL: 2x2 tiles x 64 band planes = 256 scattered ranges.
#
# Methods (each measurement runs in a FRESH process: no vsicurl RAM cache
# carry-over, cold open every time, like a production first-touch):
#   g1    single GDALRaster handle, read_ds(bands=1:64, as_raw)      [baseline]
#   gmt   + open option NUM_THREADS=ALL_CPUS (GTiff multi-threaded
#           read: parallel tile decode + parallel range prefetch)
#   gp8   8 forked workers x 8 bands each, own handle per worker
#   gp16  16 forked workers x 4 bands each (local regime only)
#   ck    cptkirk::ck_warp_to_buffer, native grid, near                [incumbent]
#   raw   readBin of a pre-staged headerless BSQ .bin (local floor)
#
# Usage:
#   Rscript mb-read-bench.R remote            # remote phase (source.coop)
#   Rscript mb-read-bench.R local             # local phase (stages to /dev/shm)
#   Rscript mb-read-bench.R run <method> <src> <xoff> <yoff>   # internal

suppressMessages(library(gdalraster))
Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR",
           GDAL_HTTP_MULTIPLEX = "YES")

TILE <- paste0("https://data.source.coop/tge-labs/aef/v1/annual/2021/36S/",
               "xekh5rjs4wg6wb9b4-0000000000-0000000000.tiff")
VSI  <- paste0("/vsicurl/", TILE)
NPX  <- 2048L
NB   <- 64L

args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args) >= 1) args[[1]] else "remote"

# Per-band value sums, orientation-invariant. Handles both carriers:
# raw Int8 BSQ (cptkirk, staged .bin) and R integers (read_ds returns
# integers for Int8; as_raw only applies to Byte).
band_sums <- function(x, b) {
  npx <- as.numeric(NPX) * NPX
  vapply(b, function(i) {
    seg <- x[((i - 1) * npx + 1):(i * npx)]
    if (is.raw(seg))
      sum(as.numeric(readBin(seg, integer(), n = length(seg), size = 1L,
                             signed = TRUE)))
    else sum(as.numeric(seg))
  }, numeric(1))
}

# ---------------------------------------------------------------------------
if (mode == "run") {
  method <- args[[2]]; src <- args[[3]]
  xoff <- as.integer(args[[4]]); yoff <- as.integer(args[[5]])
  is_remote <- startsWith(src, "/vsicurl/")

  read_bands <- function(bands, oo = NULL) {
    t0 <- proc.time()[["elapsed"]]
    ds <- if (is.null(oo)) new(GDALRaster, src)
          else new(GDALRaster, src, TRUE, oo)
    t_open <- proc.time()[["elapsed"]] - t0
    v <- read_ds(ds, bands = bands, xoff = xoff, yoff = yoff,
                 xsize = NPX, ysize = NPX, as_raw = TRUE)
    ds$close()
    list(open = t_open, bytes = v)
  }

  t0 <- proc.time()[["elapsed"]]
  res <- switch(method,
    g1 = read_bands(1:NB),
    gmt = read_bands(1:NB, oo = "NUM_THREADS=ALL_CPUS"),
    gp8 = ,
    gp16 = {
      # mirai daemons, one GDAL handle per daemon (never fork: GDAL and
      # libcurl TLS state are not fork-safe). Parts stage to /dev/shm so
      # result serialization stays out of the read measurement; daemon
      # spawn happens before the clock starts (garry pools are standing
      # in production).
      nw <- if (method == "gp8") 8L else 16L
      mirai::daemons(nw)
      on.exit(mirai::daemons(0), add = TRUE)
      sets <- split(1:NB, rep(seq_len(nw), each = NB / nw))
      outs <- vapply(seq_len(nw), function(i)
        tempfile(sprintf("part%02d-", i), tmpdir = "/dev/shm",
                 fileext = ".bin"), character(1))
      t0 <- proc.time()[["elapsed"]]
      jobs <- Map(function(b, o) mirai::mirai({
        suppressMessages(library(gdalraster))
        Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR",
                   GDAL_HTTP_MULTIPLEX = "YES")
        ds <- new(GDALRaster, src)
        v <- read_ds(ds, bands = b, xoff = xoff, yoff = yoff,
                     xsize = npx, ysize = npx)
        ds$close()
        writeBin(as.integer(v), o, size = 4L)
        TRUE
      }, src = src, b = b, o = o, xoff = xoff, yoff = yoff, npx = NPX),
      sets, outs)
      ok <- vapply(jobs, function(j) isTRUE(j[]), logical(1))
      t_read <- proc.time()[["elapsed"]] - t0
      if (!all(ok)) stop("mirai worker failed: ",
                         paste(vapply(jobs[!ok], function(j)
                           paste(deparse(j$data), collapse = " "),
                           character(1)), collapse = "; "))
      bytes <- do.call(c, lapply(outs, function(o)
        readBin(o, integer(), n = file.size(o) / 4L)))
      unlink(outs)
      list(open = NA_real_, bytes = bytes, read = t_read)
    },
    ck = {
      # native grid: te from the geotransform, identity resample
      ds <- new(GDALRaster, src); gt <- ds$getGeoTransform()
      crs <- ds$getProjection(); ds$close()
      xs <- gt[[1]] + c(xoff, xoff + NPX) * gt[[2]]
      ys <- gt[[4]] + c(yoff, yoff + NPX) * gt[[6]]
      r <- cptkirk::ck_warp_to_buffer(
        if (is_remote) TILE else src, t_srs = crs,
        te = c(min(xs), min(ys), max(xs), max(ys)), ts = c(NPX, NPX),
        r = "near")
      list(open = NA_real_, bytes = r$data)
    },
    raw = {
      bin <- sub("\\.tif$", ".bin", src)
      list(open = NA_real_,
           bytes = readBin(bin, "raw", n = file.size(bin)))
    },
    stop("unknown method"))
  t_all <- proc.time()[["elapsed"]] - t0
  bs <- band_sums(res$bytes, c(1L, 64L))
  cat(sprintf(
    "RUN %s total=%.2f open=%.2f read=%.2f mb=%.1f b1=%.0f b64=%.0f\n",
    method, t_all, res$open,
    if (is.null(res$read)) NA_real_ else res$read,
    length(res$bytes) / 2^20, bs[[1]], bs[[2]]))
  quit(save = "no")
}

# ---------------------------------------------------------------------------
self <- normalizePath(sub("--file=", "", grep("--file=", commandArgs(),
                                              value = TRUE)[[1]]))
run1 <- function(method, src, xoff, yoff) {
  out <- tryCatch(
    system2("Rscript", c(self, "run", method, src, xoff, yoff),
            stdout = TRUE, stderr = FALSE, timeout = 420),
    warning = function(w) character(0))
  line <- grep("^RUN ", out, value = TRUE)
  if (length(line) != 1L) sprintf("RUN %s FAILED", method) else line
}

if (mode == "multi") {
  # Multi-file x multi-band: a 2048x2048 window straddling the corner
  # junction of 4 adjacent tiles (each contributes a 1024^2 quadrant,
  # 64 bands) -- the real acquire_aef shape. cptkirk pools files AND
  # bands in one async runtime; the GDAL contender fans (tile x
  # band-set) tasks over mirai daemons.
  BASE <- paste0("https://data.source.coop/tge-labs/aef/v1/annual/",
                 "2021/36S/xekh5rjs4wg6wb9b4-%010d-%010d.tiff")
  tiles <- data.frame(   # quadrant window inside each tile (px)
    row = c(0L, 0L, 8192L, 8192L), col = c(0L, 8192L, 0L, 8192L),
    xoff = c(7168L, 0L, 7168L, 0L), yoff = c(7168L, 7168L, 0L, 0L))
  tiles$url <- sprintf(BASE, tiles$row, tiles$col)
  Q <- 1024L
  te <- c(571680, 8597120, 592160, 8617600)   # junction box, EPSG:32736

  qsums <- function(x, nb = NB) {   # per-band sums of one quadrant part
    npx <- as.numeric(Q) * Q
    v <- if (is.raw(x)) readBin(x, integer(), n = length(x), size = 1L,
                                signed = TRUE) else x
    vapply(seq_len(nb), function(i)
      sum(as.numeric(v[((i - 1) * npx + 1):(i * npx)])), numeric(1))
  }

  run_multi <- function(method) {
    # cold caches for every measurement: multi mode runs in one
    # process, so the vsicurl RAM cache (host and daemons) must not
    # carry ranges between reps
    gdalraster::vsi_curl_clear_cache(quiet = TRUE)
    if (method == "mgp8")
      mirai::everywhere({
        suppressMessages(library(gdalraster))
        gdalraster::vsi_curl_clear_cache(quiet = TRUE)
      })
    t0 <- proc.time()[["elapsed"]]
    sums <- switch(method,
      mg1 = {   # sequential: one handle per tile, 64 bands each
        acc <- numeric(NB)
        for (i in seq_len(nrow(tiles))) {
          ds <- new(GDALRaster, paste0("/vsicurl/", tiles$url[[i]]))
          v <- read_ds(ds, bands = 1:NB, xoff = tiles$xoff[[i]],
                       yoff = tiles$yoff[[i]], xsize = Q, ysize = Q)
          ds$close()
          acc <- acc + qsums(v)
        }
        acc
      },
      mgp8 = {   # 4 tiles x 8 band-sets = 32 tasks over 8 mirai daemons
        sets <- split(1:NB, rep(1:8, each = 8L))
        grid <- expand.grid(ti = seq_len(nrow(tiles)),
                            si = seq_along(sets))
        jobs <- lapply(seq_len(nrow(grid)), function(k) {
          ti <- grid$ti[[k]]
          mirai::mirai({
            suppressMessages(library(gdalraster))
            Sys.setenv(GDAL_DISABLE_READDIR_ON_OPEN = "EMPTY_DIR",
                       GDAL_HTTP_MULTIPLEX = "YES")
            ds <- new(GDALRaster, src)
            v <- read_ds(ds, bands = b, xoff = xoff, yoff = yoff,
                         xsize = q, ysize = q)
            ds$close()
            as.integer(v)
          }, src = paste0("/vsicurl/", tiles$url[[ti]]),
             b = sets[[grid$si[[k]]]], xoff = tiles$xoff[[ti]],
             yoff = tiles$yoff[[ti]], q = Q)
        })
        parts <- lapply(jobs, function(j) j[])
        bad <- vapply(parts, mirai::is_error_value, logical(1))
        if (any(bad)) stop("mirai worker failed")
        acc <- numeric(NB)
        for (k in seq_len(nrow(grid))) {
          bs <- sets[[grid$si[[k]]]]
          acc[bs] <- acc[bs] + qsums(parts[[k]], nb = length(bs))
        }
        acc
      },
      mck = {    # one cptkirk pool across all 4 files x 64 bands
        r <- cptkirk::ck_warp_to_buffer(tiles$url, t_srs = "EPSG:32736",
                                        te = te, ts = c(2L * Q, 2L * Q),
                                        r = "near")
        npx <- as.numeric(2L * Q)^2
        vapply(seq_len(NB), function(i) {
          seg <- r$data[((i - 1) * npx + 1):(i * npx)]
          sum(as.numeric(readBin(seg, integer(), n = length(seg),
                                 size = 1L, signed = TRUE)))
        }, numeric(1))
      },
      mck4 = {   # cptkirk without cross-file pooling: one call per tile
        acc <- numeric(NB)
        for (i in seq_len(nrow(tiles))) {
          x0 <- if (tiles$col[[i]] == 0L) te[[1]] else te[[1]] + Q * 10
          y0 <- if (tiles$row[[i]] == 0L) te[[2]] else te[[2]] + Q * 10
          r <- cptkirk::ck_warp_to_buffer(tiles$url[[i]],
                 t_srs = "EPSG:32736",
                 te = c(x0, y0, x0 + Q * 10, y0 + Q * 10),
                 ts = c(Q, Q), r = "near")
          acc <- acc + qsums(r$data)
        }
        acc
      },
      stop("unknown method"))
    t_all <- proc.time()[["elapsed"]] - t0
    sprintf("RUN %s total=%.2f b1=%.0f b64=%.0f", method, t_all,
            sums[[1]], sums[[NB]])
  }

  mirai::daemons(8)
  on.exit(mirai::daemons(0), add = TRUE)
  methods <- c("mg1", "mgp8", "mck", "mck4")
  for (rep in 1:2) for (m in methods) {
    line <- tryCatch(run_multi(m), error = function(e)
      sprintf("RUN %s FAILED: %s", m, conditionMessage(e)))
    cat(sprintf("[rep %d] %s\n", rep, line))
  }
} else if (mode == "remote") {
  cat("== remote:", TILE, "==\n")
  # mdim probe: can the multidim API even see a classic GTiff?
  md <- tryCatch(mdim_info(VSI), error = function(e)
    paste("mdim_info error:", conditionMessage(e)))
  cat("mdim probe:", substr(paste(md, collapse = " "), 1, 200), "\n")
  methods <- c("g1", "gmt", "gp8", "ck")
  for (rep in 1:2) for (m in methods)
    cat(sprintf("[rep %d] %s\n", rep, run1(m, VSI, 2048L, 2048L)))
} else if (mode == "local") {
  stage <- "/dev/shm/aefwin.tif"
  if (!file.exists(stage)) {
    cat("staging window to", stage, "...\n")
    st <- system.time(translate(VSI, stage, cl_arg = c(
      "-srcwin", "2048", "2048", "2048", "2048",
      "-co", "COMPRESS=ZSTD", "-co", "TILED=YES",
      "-co", "BLOCKXSIZE=1024", "-co", "BLOCKYSIZE=1024",
      "-co", "INTERLEAVE=BAND"), quiet = TRUE))
    cat(sprintf("staged in %.1fs (%.0f MB)\n", st[["elapsed"]],
                file.size(stage) / 2^20))
  }
  bin <- "/dev/shm/aefwin.bin"
  if (!file.exists(bin)) {
    # headerless BSQ Int8 (the ENVI driver rejects Int8; write it
    # directly -- writeBin size=1 stores two's complement, matching
    # what readBin(signed = TRUE) recovers)
    ds <- new(GDALRaster, stage)
    v <- read_ds(ds, bands = 1:NB, xoff = 0, yoff = 0,
                 xsize = NPX, ysize = NPX)
    ds$close()
    writeBin(as.integer(v), bin, size = 1L)
  }
  methods <- c("g1", "gmt", "gp8", "gp16", "ck", "raw")
  for (rep in 1:3) for (m in methods)
    cat(sprintf("[rep %d] %s\n", rep, run1(m, stage, 0L, 0L)))
}
