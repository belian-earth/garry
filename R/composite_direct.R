#' @include passes.R gdal_adapter.R ops.R scheduler.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Phase 12d: GDAL-direct temporal-composite fast path.
#
# For the composite shape -- GTI source reads feeding a single fused compute
# stage that masks per slice and reduces over time -- the staged scheduler's
# read -> R -> store -> per-chunk-upload -> per-slice fused kernel is pure
# overhead. This path instead warps each slice's f32 pixels DIRECTLY into a
# device-bound buffer (gdalraster MEM:::DATAPOINTER, no R double carrier),
# assembles two contiguous (T, ny, nx) cubes (band + mask), and runs ONE lean
# kernel: mask = M(fmask_cube); reduce(F(band_cube, mask)). M/F and the reduce
# op are lifted straight from the plan's IR, so the maths is garry's own.
# Measured ~22% faster than the scheduler on HLS median at a fraction of the
# memory of the 55-input whole-grid fused kernel.
#
# Gated by options(garry.composite_direct = TRUE); requires the raw-f32 upload
# path (patched anvl) and a mirai daemon pool. Non-matching plans fall through
# to the scheduler (`.cd_spec` returns NULL).
# ---------------------------------------------------------------------------

# Given a ReduceNode, lift one band's pieces: per-slice band sources, per-slice
# fmask sources, the masked-apply fn F and mask fn M (NULL if unmasked). NULL if
# the sub-shape isn't reconstructible.
.cd_reduce_spec <- function(gg, red) {
  if (!S7::S7_inherits(red, ReduceNode)) return(NULL)
  if (!("t" %in% red@over) ||
      !(red@op %in% c("median", "mean", "min", "max", "sum", "prod")))
    return(NULL)
  if (length(red@parents) != 1L) return(NULL)
  stk <- gg(red@parents[[1L]])
  if (!S7::S7_inherits(stk, StackNode) || !length(stk@parents)) return(NULL)
  masked <- stk@parents
  first <- gg(masked[[1L]])
  if (S7::S7_inherits(first, MapNode)) {
    if (length(first@parents) != 2L) return(NULL)
    mask0 <- gg(first@parents[[2L]])
    if (!S7::S7_inherits(mask0, MapNode) || length(mask0@parents) != 1L)
      return(NULL)
    band_srcs <- vapply(masked, function(id) gg(id)@parents[[1L]], integer(1))
    fmask_srcs <- vapply(masked, function(id)
      gg(gg(id)@parents[[2L]])@parents[[1L]], integer(1))
    if (!all(vapply(c(band_srcs, fmask_srcs),
                    function(id) S7::S7_inherits(gg(id), SourceNode), logical(1))))
      return(NULL)
    list(band = band_srcs, fmask = fmask_srcs, F = first@fn, M = mask0@fn,
         op = red@op, nan_rm = red@nan_rm)
  } else if (S7::S7_inherits(first, SourceNode)) {
    list(band = as.integer(masked), fmask = integer(0), F = NULL, M = NULL,
         op = red@op, nan_rm = red@nan_rm)
  } else NULL
}

# Recognise the reconstructible composite shape and lift its pieces, or NULL.
# Shape: N GTI source_reads feeding ONE fused compute sink whose output is either
# a single ReduceNode over "t" (single band) or a StackNode along "band" over one
# ReduceNode per band (multi-band, sharing one mask). Each ReduceNode is fed by a
# StackNode of homogeneous per-slice masked MapNodes (F) over (band SourceNode,
# mask MapNode (M) over fmask SourceNode) -- or bare SourceNodes when unmasked.
.cd_spec <- function(plan) {
  if (!isTRUE(getOption("garry.composite_direct", FALSE))) return(NULL)
  if (!.g_has_raw_upload()) return(NULL)
  graph <- plan@graph
  sink <- plan@stages[[plan@sink]]
  if (sink@kind != "compute") return(NULL)
  # Every GTI source must be a `source_read` stage with a .meta.rds sidecar
  # (so its items can be fetched locally). Intermediate compute stages are
  # fine -- the lean path recomputes from sources regardless of how the
  # planner split the graph (e.g. a shared mask materialised on its own).
  src_stages <- Filter(function(s) s@kind == "source_read", plan@stages)
  if (!length(src_stages)) return(NULL)
  gg <- function(id) graph_get(graph, id)
  for (s in src_stages) {
    n <- gg(s@members[[1L]])
    if (!grepl("^GTI:", n@path)) return(NULL)
    if (!file.exists(paste0(sub("^GTI:", "", n@path), ".meta.rds"))) return(NULL)
  }
  src_ids <- vapply(src_stages, function(s) gg(s@members[[1L]])@id, integer(1))
  top <- gg(sink@members[[length(sink@members)]])   # the sink's output node
  if (S7::S7_inherits(top, ReduceNode)) {
    reduces <- list(top)
  } else if (S7::S7_inherits(top, StackNode) && identical(top@along, "band")) {
    reduces <- lapply(top@parents, gg)
  } else return(NULL)

  specs <- lapply(reduces, function(r) .cd_reduce_spec(gg, r))
  if (any(vapply(specs, is.null, logical(1)))) return(NULL)
  # every band/fmask leaf must be a fetchable source_read source
  leaves <- unlist(lapply(specs, function(s) c(s$band, s$fmask)))
  if (!all(leaves %in% src_ids)) return(NULL)
  s1 <- specs[[1L]]; masked <- !is.null(s1$M)
  ok <- vapply(specs, function(s)
    identical(s$op, s1$op) && identical(s$nan_rm, s1$nan_rm) &&
      (!is.null(s$M)) == masked &&
      (!masked || identical(s$fmask, s1$fmask)),   # one shared mask across bands
    logical(1))
  if (!all(ok)) return(NULL)
  list(op = s1$op, nan_rm = s1$nan_rm, F = s1$F, M = s1$M,
       band_srcs = lapply(specs, function(s) s$band), fmask_srcs = s1$fmask,
       n_bands = length(specs), grid = sink@grid, device = sink@device)
}

# One source's fused fetch+warp, run in a daemon: fetch this slice's item
# windows to local tmpfs, build a small per-slice GTI (much faster to open
# than one shared many-tile index FILTERed per slice), then warp the mosaic
# straight into a raw f32 buffer via MEM:::DATAPOINTER (GDAL writes f32 into
# memory we hold; no R double). Writes the payload to `bin`.
# `j` carries only this slice's varying data (locs, dt, bb, nodata, bin); `k`
# is the grid-constant bundle passed once via mirai `.args` (embedding it in
# every task instead throttles the dispatcher and starves the daemon pool).
.cd_fetch_warp <- function(j, k) {
  nx <- k$nx; ny <- k$ny
  buf <- rep(writeBin(NaN, raw(), size = 4L), nx * ny)   # all-nodata default
  tf <- 0; tw <- 0
  err <- tryCatch({
    gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")
    d <- tempfile("cd"); dir.create(d); on.exit(unlink(d, recursive = TRUE))
    if (!length(j$locs)) stop("no items for this slice")
    lf <- file.path(d, sprintf("i%03d.tif", seq_along(j$locs)))
    tf <- system.time(for (i in seq_along(j$locs)) tryCatch(
      garry:::gdal_fetch_window(j$locs[i], lf[i], k$ex, k$cr),
      error = function(e) garry:::gdal_nodata_window(lf[i], k$ex, k$cr, 255)))[["elapsed"]]
    tw <- system.time({
      ent <- data.frame(location = lf, datetime = j$dt,
                        xmin = j$bb[, 1], ymin = j$bb[, 2],
                        xmax = j$bb[, 3], ymax = j$bb[, 4])
      fgb <- file.path(d, "s.fgb"); garry::gti_index_create(ent, fgb, crs = k$cr)
      ptr <- gdalraster:::.get_data_ptr(buf)
      s <- methods::new(gdalraster::GDALRaster, paste0("GTI:", fgb), TRUE, k$oo)
      dsn <- sprintf(
        "MEM:::DATAPOINTER=%s,PIXELS=%d,LINES=%d,BANDS=1,DATATYPE=Float32,GEOTRANSFORM=%s",
        ptr, nx, ny, k$gtstr)
      o <- methods::new(gdalraster::GDALRaster, dsn, FALSE)
      o$setProjection(k$wkt)
      cl <- c("-r", "near", "-q", "-dstnodata", "nan")
      if (length(j$nodata) == 1L)
        cl <- c(cl, "-srcnodata", format(j$nodata, scientific = FALSE))
      gdalraster::warp(s, o, "", cl_arg = cl)
      s$close(); o$close()
    })[["elapsed"]]
    NA_character_
  }, error = function(e) conditionMessage(e))
  writeBin(buf, j$bin)   # always write a complete slice (real or all-NaN)
  list(err = err, tf = tf, tw = tw)
}

#' Execute a composite-shape plan via the GDAL-direct fast path.
#' @keywords internal
.execute_composite_direct <- function(plan, spec, path = NULL, nodata = NULL) {
  .require_anvl()
  graph <- plan@graph
  ex <- spec$grid@extent; cr <- spec$grid@crs
  nx <- spec$grid@dims[["x"]]; ny <- spec$grid@dims[["y"]]
  tmp <- file.path(if (dir.exists("/dev/shm")) "/dev/shm" else tempdir(),
                   sprintf("cdirect-%d", Sys.getpid()))
  dir.create(tmp); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

  # Per-source (node id -> its slice's item rows + warp target .bin).
  srcs <- Filter(function(s) s@kind == "source_read", plan@stages)
  meta_cache <- new.env(parent = emptyenv())
  info <- lapply(srcs, function(s) {
    n <- graph_get(graph, s@members[[1L]]); gti <- sub("^GTI:", "", n@path)
    if (is.null(meta_cache[[gti]]))
      meta_cache[[gti]] <- readRDS(paste0(gti, ".meta.rds"))
    e <- meta_cache[[gti]]$entries
    filt <- grep("FILTER=", n@open_options, value = TRUE)
    er <- if (length(filt)) {
      sl <- sub(".*'([^']*)'.*", "\\1", filt); e[e$slice == sl, , drop = FALSE]
    } else e
    # The per-slice local GTI holds only this slice's tiles, so drop the
    # FILTER=slice open option (its `slice` field is not carried locally);
    # keep the grid pin + datetime sort.
    oo <- grep("^FILTER=", n@open_options, value = TRUE, invert = TRUE)
    list(nid = n@id, oo = oo, nodata = n@nodata, locs = er$location,
         dt = er$datetime, bb = as.matrix(er[, c("xmin","ymin","xmax","ymax")]),
         bin = file.path(tmp, sprintf("n%d.bin", n@id)))
  })
  names(info) <- vapply(info, function(x) as.character(x$nid), "")

  # Grid-constant bundle (same for every source): send ONCE via mirai .args.
  # Slim each task to its varying data so the dispatcher isn't throttled.
  K <- list(ex = ex, cr = cr, nx = nx, ny = ny,
            gtstr = paste(sprintf("%.10g", spec$grid@transform), collapse = "/"),
            wkt = gdalraster::srs_to_wkt(cr), oo = info[[1L]]$oo)
  jobs <- unname(lapply(info, function(x)
    list(locs = x$locs, dt = x$dt, bb = x$bb, nodata = x$nodata, bin = x$bin)))

  # Preload garry (hence anvl/XLA) once per daemon (else every fetch task
  # cold-inits XLA on first garry::: use) and set the vsicurl/MEM GDAL config
  # in the daemons: options set via set_config_option in the host process do
  # NOT propagate to mirai daemons, so signed vsicurl opens fail without these.
  mirai::everywhere({
    suppressMessages(library(garry)); library(gdalraster)
    gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
    gdalraster::set_config_option("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".tif")
    gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")
  })

  if (isTRUE(getOption("garry.progress", FALSE)))
    message("[composite-direct] mirai daemons connected: ",
            tryCatch(mirai::status()$connections, error = function(e) "?"))
  # FETCH + WARP fused per source, parallel across the pool. Each returns NA
  # on success or an error string; a failed slice is written as all-nodata.
  errs <- NULL
  twarp <- system.time({
    # Pass the bare namespace function (NOT a local closure): a closure defined
    # here captures this frame's environment -- the whole IR (plan/graph/info/
    # jobs) -- which mirai then serialises per task, throttling dispatch to ~2
    # concurrent. `.cd_fetch_warp`'s environment is the garry namespace, which
    # the daemons already have loaded, so nothing heavy is serialised.
    r <- mirai::mirai_map(jobs, .cd_fetch_warp, .args = list(k = K))[]
    errs <- vapply(r[vapply(r, function(x) inherits(x, "miraiError"), FALSE)],
                   conditionMessage, "")
    if (isTRUE(getOption("garry.progress", FALSE))) {
      ok <- Filter(function(x) is.list(x) && !is.null(x$tf), r)
      message(sprintf("[composite-direct] per-task sums: fetch=%.1fs warp=%.1fs (across all slices, /~16 daemons)",
                      sum(vapply(ok, function(x) x$tf, 0)), sum(vapply(ok, function(x) x$tw, 0))))
    }
  })[["elapsed"]]
  if (length(errs))
    warning(sprintf("composite-direct: %d/%d slice warps failed (e.g. %s)",
                    length(errs), length(info), errs[[1L]]), call. = FALSE)

  # COMPUTE: assemble contiguous cubes, run ONE lean kernel from the IR.
  tcomp <- system.time({
    dev <- .exec_device(spec$device)
    cube <- function(ids) {
      Tt <- length(ids)
      bytes <- do.call(c, lapply(ids, function(id)
        readBin(info[[as.character(id)]]$bin, "raw", n = ny * nx * 4L)))
      g_upload_raw(bytes, "f32", c(Tt, ny, nx), device = dev)
    }
    band_cubes <- lapply(spec$band_srcs, cube)               # N x (T, ny, nx)
    fm <- if (length(spec$fmask_srcs)) cube(spec$fmask_srcs) else NULL
    F <- spec$F; M <- spec$M; op <- spec$op; nan_rm <- spec$nan_rm
    # inp = list(band_1_cube, ..., band_N_cube[, fmask_cube]); the mask is
    # computed ONCE and shared across bands. Returns one (ny, nx) per band.
    lean <- function(inp) {
      nb <- length(inp) - (if (is.null(M)) 0L else 1L)
      mask <- if (is.null(M)) NULL else M(inp[[length(inp)]])
      lapply(seq_len(nb), function(b) {
        masked <- if (is.null(M)) inp[[b]] else F(inp[[b]], mask)
        .apply_reduce(op, masked, 1L, nan_rm)   # reduce over t (axis 1)
      })
    }
    jf <- g_jit(lean, device = dev)
    res <- g_download(jf(c(band_cubes, if (is.null(fm)) NULL else list(fm))))
  })[["elapsed"]]
  if (isTRUE(getOption("garry.progress", FALSE)))
    message(sprintf("[composite-direct] fetch+warp=%.2fs compute=%.2fs",
                    twarp, tcomp))

  mats <- lapply(res, .sv_materialise)                        # one per band
  if (is.null(path)) return(if (spec$n_bands == 1L) mats[[1L]] else mats)
  ds <- gdal_create_output(path, spec$grid,
                           nodata = if (is.null(nodata)) numeric(0) else nodata)
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  for (b in seq_along(mats))
    gdal_write_window(ds, 0L, 0L, mats[[b]], spec$grid@dtype,
                      nodata = if (is.null(nodata)) numeric(0) else nodata,
                      band = b)
  invisible(path)
}
