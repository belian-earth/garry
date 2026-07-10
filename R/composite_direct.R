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

# Walk a LINEAR mask chain (Map/Focal nodes) from `mid` back to its SourceNode.
# Returns list(chain = source->mask order, src = fmask source id, halo = sum of
# focal radii) or NULL if the chain branches or hits an unsupported node.
.cd_walk_mask <- function(gg, mid) {
  chain <- list(); h <- 0L; cur <- gg(mid)
  while (!S7::S7_inherits(cur, SourceNode)) {
    if (!(S7::S7_inherits(cur, MapNode) || S7::S7_inherits(cur, FocalNode)) ||
        length(cur@parents) != 1L) return(NULL)
    if (S7::S7_inherits(cur, FocalNode)) h <- h + cur@radius
    chain <- c(list(cur), chain)
    cur <- gg(cur@parents[[1L]])
  }
  list(chain = chain, src = cur@id, halo = h)
}

# Replay a mask chain (Map/Focal nodes) on the fmask CUBE (t,y,x), vectorised
# over time: pad spatially by the chain halo, then apply each node -- Map fns
# elementwise, Focal fns as spatial stencils (g_shift_slice over the last two
# dims, batched across time). Runs inside the jitted kernel. Returns the mask
# cube (t, ny, nx).
.gd_replay_mask <- function(fm, chain, halo, ny, nx) {
  mc <- if (halo > 0L) g_pad(fm, halo, NaN) else fm
  cy <- ny + 2L * halo; cx <- nx + 2L * halo
  for (node in chain) {
    if (S7::S7_inherits(node, FocalNode)) {
      r <- node@radius; oy <- cy - 2L * r; ox <- cx - 2L * r
      offs <- expand.grid(dx = -r:r, dy = -r:r)     # match .eval_node order
      shifts <- lapply(seq_len(nrow(offs)), function(i)
        g_shift_slice(mc, offs$dy[i], offs$dx[i], oy, ox, r))
      mc <- if (length(node@weights) > 0L)
        Reduce(`+`, Map(function(s, w) s * w, shifts, as.list(node@weights)))
      else node@fn(shifts)
      cy <- oy; cx <- ox
    } else {
      mc <- node@fn(mc)                              # MapNode: elementwise
    }
  }
  mc
}

# Warm a daemon's XLA/PJRT client (one trivial jit) so the first real compute
# task doesn't pay the ~3s cold init on the critical path.
#' @keywords internal
#' @export
.gd_warm <- function() {
  .require_anvl()
  g_download(g_jit(function(inp) inp[[1L]] + 1)(list(anvl::nv_array(as.double(1:4)))))
  invisible(TRUE)
}

# Daemon task body (parallel compute spike): read one band's per-slice .bin
# cubes (and the shared fmask cube) from tmpfs, replay mask + masked-apply +
# temporal reduce, return the (ny,nx) result as a raw f32 payload. `k` is the
# grid-constant + slimmed-fn bundle passed once via mirai .args.
#' @keywords internal
#' @export
.gd_compute_band <- function(job, k) {
  .require_anvl()
  dev <- .exec_device(k$dev)
  cube <- function(bins) g_upload_raw(
    do.call(c, lapply(bins, function(f) readBin(f, "raw", n = k$ny * k$nx * 4L))),
    "f32", c(length(bins), k$ny, k$nx), device = dev)
  masked <- length(k$fmask_bins) > 0L
  lean1 <- function(inp) {
    if (masked) {
      mask <- .gd_replay_mask(inp[[2L]], k$chain, k$halo, k$ny, k$nx)
      m <- k$F(inp[[1L]], mask)
    } else m <- inp[[1L]]
    .apply_reduce(k$op, m, 1L, k$nan_rm)
  }
  band <- cube(job$band_bins)
  inputs <- if (masked) list(band, cube(k$fmask_bins)) else list(band)
  g_download_raw(g_jit(lean1, device = dev)(inputs))
}

# Given a ReduceNode, lift one band's pieces: per-slice band + fmask sources,
# the masked-apply fn F, and the mask CHAIN (Map/Focal nodes, replayed on the
# cube; may include morphology focals). NULL if not reconstructible.
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
    band_srcs <- vapply(masked, function(id) gg(id)@parents[[1L]], integer(1))
    if (!all(vapply(band_srcs,
                    function(id) S7::S7_inherits(gg(id), SourceNode), logical(1))))
      return(NULL)
    m0 <- .cd_walk_mask(gg, first@parents[[2L]]); if (is.null(m0)) return(NULL)
    fmask_srcs <- vapply(masked, function(id) {
      w <- .cd_walk_mask(gg, gg(id)@parents[[2L]])
      if (is.null(w)) NA_integer_ else w$src
    }, integer(1))
    if (anyNA(fmask_srcs)) return(NULL)
    list(band = band_srcs, fmask = fmask_srcs, F = first@fn,
         mask_chain = m0$chain, halo = m0$halo, op = red@op, nan_rm = red@nan_rm)
  } else if (S7::S7_inherits(first, SourceNode)) {
    list(band = as.integer(masked), fmask = integer(0), F = NULL,
         mask_chain = list(), halo = 0L, op = red@op, nan_rm = red@nan_rm)
  } else NULL
}

# Recognise the reconstructible composite shape and lift its pieces, or NULL.
# Shape: N GTI source_reads feeding ONE fused compute sink whose output is either
# a single ReduceNode over "t" (single band) or a StackNode along "band" over one
# ReduceNode per band (multi-band, sharing one mask). Each ReduceNode is fed by a
# StackNode of homogeneous per-slice masked MapNodes (F) over (band SourceNode,
# mask MapNode (M) over fmask SourceNode) -- or bare SourceNodes when unmasked.
.cd_spec <- function(plan) {
  if (!isTRUE(garry_opt("composite_direct"))) return(NULL)
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
  s1 <- specs[[1L]]; masked <- length(s1$mask_chain) > 0L
  ok <- vapply(specs, function(s)
    identical(s$op, s1$op) && identical(s$nan_rm, s1$nan_rm) &&
      (length(s$mask_chain) > 0L) == masked &&
      (!masked || identical(s$fmask, s1$fmask)),   # one shared mask across bands
    logical(1))
  if (!all(ok)) return(NULL)
  # Smart routing: the whole-grid compute runs single-process here (no overlap
  # with the fetch drain). For heavy composites the scheduler's warm, parallel,
  # overlapped compute pool wins -- but ONLY when it exists (a garry_daemons
  # split pool). On a single pool composite_direct is best regardless, so only
  # fall through when both heavy AND pooled.
  n_bands <- length(specs); n_slices <- length(s1$band)
  grid_px <- sink@grid@dims[["x"]] * sink@grid@dims[["y"]]
  weight <- (n_bands + (s1$halo > 0L)) * n_slices * grid_px
  if (weight > garry_opt("gd_compute_budget") && .gd_pooled()) return(NULL)
  list(op = s1$op, nan_rm = s1$nan_rm, F = s1$F, mask_chain = s1$mask_chain,
       halo = s1$halo, band_srcs = lapply(specs, function(s) s$band),
       fmask_srcs = s1$fmask, n_bands = n_bands,
       grid = sink@grid, device = sink@device)
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

# Is a garry_daemons() split read/compute pool active? (Both named profiles
# have daemons.) The scheduler's warm compute pool only exists when pooled.
.gd_pooled <- function() {
  n_of <- function(p) {
    st <- tryCatch(mirai::status(.compute = p), error = function(e) NULL)
    if (is.null(st) || !is.numeric(st$connections)) 0L else as.integer(st$connections)
  }
  n_of("garry_read") > 0L && n_of("garry_compute") > 0L
}

# The mirai profile composite_direct dispatches to: the read pool when pooled
# (a garry_daemons split), else mirai's default profile. Unqualified everywhere/
# mirai_map hit the empty default under a split pool and error.
.gd_profile <- function() if (.gd_pooled()) "garry_read" else "default"

# Fetch each GTI source's slice items and warp its f32 pixels straight into a
# per-source .bin on tmpfs (parallel across the pool). Returns `info`: keyed by
# source node id, each with its .bin path. `grid` supplies the spatial target
# (nx/ny/transform/crs); every source is pinned to it. Shared by the lean cube
# path and the general IR-replay path.
.gd_warp_sources <- function(plan, grid, tmp) {
  graph <- plan@graph
  ex <- grid@extent; cr <- grid@crs
  nx <- grid@dims[["x"]]; ny <- grid@dims[["y"]]
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
    # FILTER=slice open option (its `slice` field is not carried locally).
    oo <- grep("^FILTER=", n@open_options, value = TRUE, invert = TRUE)
    list(nid = n@id, oo = oo, nodata = n@nodata, locs = er$location,
         dt = er$datetime, bb = as.matrix(er[, c("xmin","ymin","xmax","ymax")]),
         bin = file.path(tmp, sprintf("n%d.bin", n@id)))
  })
  names(info) <- vapply(info, function(x) as.character(x$nid), "")
  # Grid-constant bundle (same for every source): send ONCE via mirai .args.
  K <- list(ex = ex, cr = cr, nx = nx, ny = ny,
            gtstr = paste(sprintf("%.10g", grid@transform), collapse = "/"),
            wkt = gdalraster::srs_to_wkt(cr), oo = info[[1L]]$oo)
  jobs <- unname(lapply(info, function(x)
    list(locs = x$locs, dt = x$dt, bb = x$bb, nodata = x$nodata, bin = x$bin)))
  # Preload garry once per daemon (else fetch tasks cold-init XLA) and set the
  # vsicurl/MEM config in the daemons (set_config_option in the host does not
  # propagate to mirai daemons). Target the read profile under a split pool.
  prof <- .gd_profile()
  mirai::everywhere({
    suppressMessages(library(garry)); library(gdalraster)
    gdalraster::set_config_option("GDAL_DISABLE_READDIR_ON_OPEN", "EMPTY_DIR")
    gdalraster::set_config_option("CPL_VSIL_CURL_ALLOWED_EXTENSIONS", ".tif")
    gdalraster::set_config_option("GDAL_MEM_ENABLE_OPEN", "YES")
  }, .compute = prof)
  progress <- isTRUE(getOption("garry.progress", FALSE))
  # Pass the bare namespace function (NOT a local closure): a local closure
  # captures this frame -- the whole IR -- which mirai serialises per task,
  # throttling dispatch. `.cd_fetch_warp`'s env is the garry namespace.
  t <- system.time({
    r <- mirai::mirai_map(jobs, .cd_fetch_warp, .args = list(k = K),
                          .compute = prof)[]
    errs <- vapply(r[vapply(r, function(x) inherits(x, "miraiError"), FALSE)],
                   conditionMessage, "")
    if (progress) {
      ok <- Filter(function(x) is.list(x) && !is.null(x$tf), r)
      message(sprintf("[gdal-direct] per-task sums: fetch=%.1fs warp=%.1fs",
                      sum(vapply(ok, function(x) x$tf, 0)),
                      sum(vapply(ok, function(x) x$tw, 0))))
    }
  })[["elapsed"]]
  if (length(errs))
    warning(sprintf("gdal-direct: %d/%d source warps failed (e.g. %s)",
                    length(errs), length(info), errs[[1L]]), call. = FALSE)
  if (progress) message(sprintf("[gdal-direct] fetch+warp=%.2fs", t))
  info
}

# tmpfs dir for a run's per-source .bin payloads.
.gd_tmp <- function() {
  tmp <- file.path(if (dir.exists("/dev/shm")) "/dev/shm" else tempdir(),
                   sprintf("gdirect-%d", Sys.getpid()))
  dir.create(tmp); tmp
}

#' Execute a no-focal composite via the lean GDAL-direct cube path.
#' @keywords internal
.execute_composite_direct <- function(plan, spec, path = NULL, nodata = NULL) {
  .require_anvl()
  nx <- spec$grid@dims[["x"]]; ny <- spec$grid@dims[["y"]]
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  info <- .gd_warp_sources(plan, spec$grid, tmp)

  bin_of <- function(ids) vapply(ids, function(id) info[[as.character(id)]]$bin, "")
  parallel <- isTRUE(garry_opt("gd_parallel")) && spec$n_bands > 1L
  masked <- length(spec$fmask_srcs) > 0L
  # COMPUTE. Default: one lean whole-grid kernel in this process. Spike
  # (garry.gd_parallel): fan the per-band medians out to daemons reading the
  # shared .bin cubes, XLA pre-warmed, so the compute parallelises across bands.
  tcomp <- system.time({
    if (parallel) {
      prof <- .gd_profile()
      mirai::everywhere(try(garry:::.gd_warm(), silent = TRUE), .compute = prof)
      K2 <- list(chain = lapply(spec$mask_chain, function(n) {
                   n@fn <- .slim_fn(n@fn); n }),
                 F = if (is.null(spec$F)) NULL else .slim_fn(spec$F),
                 op = spec$op, nan_rm = spec$nan_rm, halo = spec$halo,
                 ny = ny, nx = nx, dev = spec$device,
                 fmask_bins = if (masked) bin_of(spec$fmask_srcs) else character(0))
      band_jobs <- lapply(spec$band_srcs, function(ids)
        list(band_bins = bin_of(ids)))
      res <- mirai::mirai_map(band_jobs, .gd_compute_band, .args = list(k = K2),
                              .compute = prof)[]
    } else {
      dev <- .exec_device(spec$device)
      cube <- function(ids)
        g_upload_raw(do.call(c, lapply(ids, function(id)
          readBin(info[[as.character(id)]]$bin, "raw", n = ny * nx * 4L))),
          "f32", c(length(ids), ny, nx), device = dev)
      band_cubes <- lapply(spec$band_srcs, cube)
      fm <- if (masked) cube(spec$fmask_srcs) else NULL
      F <- spec$F; chain <- spec$mask_chain; halo <- spec$halo
      op <- spec$op; nan_rm <- spec$nan_rm; nyy <- ny; nxx <- nx
      nb <- length(band_cubes)
      # The mask (incl. morphology focals) is replayed ONCE on the whole fmask
      # cube, vectorised over time, and shared across bands.
      lean <- function(inp) {
        mask <- if (masked) .gd_replay_mask(inp[[nb + 1L]], chain, halo, nyy, nxx)
                else NULL
        lapply(seq_len(nb), function(b) {
          m <- if (masked) F(inp[[b]], mask) else inp[[b]]
          .apply_reduce(op, m, 1L, nan_rm)
        })
      }
      res <- g_download(g_jit(lean, device = dev)(
        c(band_cubes, if (masked) list(fm) else NULL)))
    }
  })[["elapsed"]]
  if (isTRUE(getOption("garry.progress", FALSE)))
    message(sprintf("[gdal-direct] %s compute=%.2fs",
                    if (parallel) "parallel" else "lean", tcomp))

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

# ---------------------------------------------------------------------------
# General GDAL-direct path: any cube-shaped plan (incl. FocalNode morphology
# and multi-band band-stacks). Warps every GTI source, uploads each per-slice
# array padded by the graph halo, and replays the WHOLE reachable IR through
# `.compose_stage_fn` (garry's own node evaluator with focal pad bookkeeping)
# in one jit -- so it recomputes from the raw sources regardless of how the
# planner split the graph. Higher memory than the lean cube path (per-slice
# focal ops can't be vectorised over the cube yet), so the lean path is tried
# first for the no-focal composite; this covers everything else.
# ---------------------------------------------------------------------------

#' Recognise ANY whole-grid-replayable cube plan and lift its IR, or NULL.
#' @keywords internal
.gd_spec <- function(plan) {
  if (!isTRUE(garry_opt("composite_direct")) || !isTRUE(garry_opt("gd_general")))
    return(NULL)
  if (!.g_has_raw_upload()) return(NULL)
  graph <- plan@graph
  sink <- plan@stages[[plan@sink]]
  if (sink@kind != "compute") return(NULL)          # raster (compute) sink only
  src_stages <- Filter(function(s) s@kind == "source_read", plan@stages)
  if (!length(src_stages)) return(NULL)
  for (s in src_stages) {
    n <- graph_get(graph, s@members[[1L]])
    if (!grepl("^GTI:", n@path)) return(NULL)
    if (!file.exists(paste0(sub("^GTI:", "", n@path), ".meta.rds"))) return(NULL)
  }
  sink_out <- sink@members[[length(sink@members)]]
  ids <- .reachable(graph, sink_out)                # ascending = topo
  nds <- lapply(ids, function(id) graph_get(graph, id))
  ok_type <- function(n)
    S7::S7_inherits(n, SourceNode) || S7::S7_inherits(n, MapNode) ||
    S7::S7_inherits(n, FocalNode) || S7::S7_inherits(n, StackNode) ||
    S7::S7_inherits(n, ReduceNode)
  if (!all(vapply(nds, ok_type, logical(1)))) return(NULL)   # Warp/Fused -> sched
  is_src <- vapply(nds, function(n) S7::S7_inherits(n, SourceNode), logical(1))
  input_nodes <- ids[is_src]
  src_ids <- vapply(src_stages, function(s)
    graph_get(graph, s@members[[1L]])@id, integer(1))
  if (!all(input_nodes %in% src_ids)) return(NULL)  # every leaf must be fetchable
  members <- ids[!is_src]
  halo <- .stage_halo(graph, members, input_nodes)
  # Focal composites use the fast cube-vectorised lean path (.cd_spec); the
  # general per-slice replay is slow for focal, so leave focal-bearing
  # non-composite plans to the scheduler (chunked + overlapped).
  if (halo > 0L) return(NULL)
  list(members = members, input_nodes = input_nodes, sink_out = sink_out,
       halo = halo, grid = sink@grid, device = sink@device)
}

#' Execute any cube-shaped plan via whole-grid IR replay.
#' @keywords internal
.execute_gd_general <- function(plan, gspec, path = NULL, nodata = NULL) {
  .require_anvl()
  graph <- plan@graph
  nx <- gspec$grid@dims[["x"]]; ny <- gspec$grid@dims[["y"]]
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  info <- .gd_warp_sources(plan, gspec$grid, tmp)

  tcomp <- system.time({
    dev <- .exec_device(gspec$device)
    h <- gspec$halo
    fn <- .compose_stage_fn(graph, gspec$members, gspec$input_nodes,
                            list(gspec$sink_out), h)
    inputs <- lapply(gspec$input_nodes, function(id) {
      a <- g_upload_raw(readBin(info[[as.character(id)]]$bin, "raw",
                                n = ny * nx * 4L), "f32", c(ny, nx), device = dev)
      if (h > 0L) g_pad(a, h, NaN) else a          # radius-cell NaN edge boundary
    })
    res <- g_download(g_jit(fn, device = dev)(inputs))[[.key(gspec$sink_out)]]
  })[["elapsed"]]
  if (isTRUE(getOption("garry.progress", FALSE)))
    message(sprintf("[gdal-direct] general compute=%.2fs", tcomp))

  m <- .sv_materialise(res)
  d <- dim(m)
  nb <- if (length(d) == 3L) d[[1L]] else 1L
  mats <- if (length(d) == 3L) lapply(seq_len(nb), function(b) m[b, , ]) else list(m)
  if (is.null(path)) return(if (nb == 1L) mats[[1L]] else mats)
  ds <- gdal_create_output(path, gspec$grid,
                           nodata = if (is.null(nodata)) numeric(0) else nodata)
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  for (b in seq_len(nb))
    gdal_write_window(ds, 0L, 0L, mats[[b]], gspec$grid@dtype,
                      nodata = if (is.null(nodata)) numeric(0) else nodata,
                      band = b)
  invisible(path)
}
