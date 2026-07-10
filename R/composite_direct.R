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
  a <- g_upload_raw(writeBin(as.numeric(1:4), raw(), size = 4L), "f32", c(2L, 2L))
  g_download(g_jit(function(inp) inp[[1L]] + 1)(list(a)))
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

# Pipeline daemon task: replay the cleaned mask ONCE on the whole fmask cube
# (morphology, cube-vectorised over time) and write the resulting f32 mask cube
# to one .bin, so every band's median reads it instead of recomputing the
# morphology. Runs on the compute pool while the bands are still fetching.
#' @keywords internal
#' @export
.gd_compute_mask <- function(k) {
  .require_anvl()
  dev <- .exec_device(k$dev)
  n <- length(k$fmask_bins)
  fm <- g_upload_raw(
    do.call(c, lapply(k$fmask_bins, function(f) readBin(f, "raw", n = k$ny * k$nx * 4L))),
    "f32", c(n, k$ny, k$nx), device = dev)
  cleaned <- g_jit(function(inp)
    .gd_replay_mask(inp[[1L]], k$chain, k$halo, k$ny, k$nx), device = dev)(list(fm))
  r <- g_download_raw(cleaned); attributes(r) <- NULL
  writeBin(r, k$out_bin)                       # whole cube, row-major f32
  invisible(TRUE)
}

# Pipeline daemon task: one band's median. Reads the band cube plus the shared
# cleaned-mask cube (already morphology-processed by .gd_compute_mask), applies
# the masked-apply fn F, and reduces over time -> (ny,nx) raw f32 payload. Runs
# on the compute pool while later bands are still fetching.
#' @keywords internal
#' @export
.gd_compute_masked_band <- function(job, k) {
  .require_anvl()
  dev <- .exec_device(k$dev)
  n <- length(job$band_bins)
  cube <- function(bins) g_upload_raw(
    do.call(c, lapply(bins, function(f) readBin(f, "raw", n = k$ny * k$nx * 4L))),
    "f32", c(length(bins), k$ny, k$nx), device = dev)
  band <- cube(job$band_bins)
  masked <- length(k$mask_bin) == 1L
  if (masked) {
    mask <- g_upload_raw(readBin(k$mask_bin, "raw", n = n * k$ny * k$nx * 4L),
                         "f32", c(n, k$ny, k$nx), device = dev)
    lean <- function(inp) .apply_reduce(k$op, k$F(inp[[1L]], inp[[2L]]), 1L, k$nan_rm)
    g_download_raw(g_jit(lean, device = dev)(list(band, mask)))
  } else {
    lean <- function(inp) .apply_reduce(k$op, inp[[1L]], 1L, k$nan_rm)
    g_download_raw(g_jit(lean, device = dev)(list(band)))
  }
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
  # Route heavy composites to the scheduler only when its warm parallel pool
  # exists (a split) AND we are not running composite_direct's own parallel
  # per-band path (gd_parallel), which warms the compute pool during the fetch
  # and handles the heavy split-pool case itself.
  if (weight > garry_opt("gd_compute_budget") && .gd_pooled() &&
      !isTRUE(garry_opt("gd_parallel"))) return(NULL)
  list(op = s1$op, nan_rm = s1$nan_rm, F = s1$F, mask_chain = s1$mask_chain,
       halo = s1$halo, band_srcs = lapply(specs, function(s) s$band),
       fmask_srcs = s1$fmask, n_bands = n_bands,
       grid = sink@grid, device = sink@device)
}

# One source's warp-on-read, run in a daemon: warp this slice's REMOTE item
# window(s) straight into a raw f32 buffer via MEM:::DATAPOINTER in one
# gdalwarp -- GDAL reads (windowed vsicurl), reprojects and mosaics the sources
# itself, writing f32 into memory we hold (no R double, no tmpfs GTiff, no
# local index). Writes the payload to `bin`.
# `j` carries only this slice's varying data (locs, dt, nodata, bin); `k` is
# the grid-constant bundle passed once via mirai `.args` (embedding it in every
# task instead throttles the dispatcher and starves the daemon pool).
.cd_fetch_warp <- function(j, k) {
  nx <- k$nx; ny <- k$ny
  buf <- rep(writeBin(NaN, raw(), size = 4L), nx * ny)   # all-nodata default
  tw <- 0
  err <- tryCatch({
    if (!length(j$locs)) stop("no items for this slice")
    # WARP-ON-READ (via the adapter): warp the slice's REMOTE items straight
    # into the f32 buffer in one gdalwarp -- GDAL reads (windowed vsicurl),
    # reprojects and mosaics the sources itself. No tmpfs GTiff fetch, no
    # per-slice local index. Ordered by datetime so overlap resolution (last
    # source wins) matches the GTI SORT_FIELD=datetime, highest-on-top path.
    tw <- system.time(
      buf <- gdal_warp_to_buffer(buf, nx, ny, k$gtstr, k$wkt,
                                 j$locs[order(j$dt)], j$nodata)
    )[["elapsed"]]
    NA_character_
  }, error = function(e) conditionMessage(e))
  writeBin(buf, j$bin)   # always write a complete slice (real or all-NaN)
  list(err = err, tf = 0, tw = tw)
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
.gd_warp_sources <- function(plan, grid, tmp)
  .gd_warp_collect(.gd_warp_launch(plan, grid, tmp))

# Build the per-source warp job bundle WITHOUT dispatching: `info` (keyed by
# source node id, each with its .bin path), the grid-constant bundle `K` sent
# once via mirai .args, and `jobs` (keyed by nid). Callers warp all sources at
# once (.gd_warp_launch) or per-asset (the fetch-ordered pipeline).
.gd_build_jobs <- function(plan, grid, tmp) {
  graph <- plan@graph
  cr <- grid@crs
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
    list(nid = n@id, nodata = n@nodata, locs = er$location, dt = er$datetime,
         bin = file.path(tmp, sprintf("n%d.bin", n@id)))
  })
  names(info) <- vapply(info, function(x) as.character(x$nid), "")
  K <- list(nx = nx, ny = ny,
            gtstr = paste(sprintf("%.10g", grid@transform), collapse = "/"),
            wkt = gdalraster::srs_to_wkt(cr))
  jobs <- lapply(info, function(x)
    list(locs = x$locs, dt = x$dt, nodata = x$nodata, bin = x$bin))
  list(info = info, K = K, jobs = jobs)
}

# Preload garry once per daemon (else fetch tasks cold-init XLA) and set the
# vsicurl/MEM config in the fetch daemons (set_config_option in the host does
# not propagate to mirai daemons).
.gd_daemon_prep <- function(prof) {
  mirai::everywhere({
    suppressMessages(library(garry))
    garry:::gdal_set_direct_config()
  }, .compute = prof)
}

# Launch the parallel warp-on-read WITHOUT blocking (one mirai_map over ALL
# sources). Returns a handle to collect later, so the caller can warm the
# compute pool while the fetch drains. Pass the BARE namespace function (a local
# closure would capture the whole IR frame and throttle dispatch per task).
.gd_warp_launch <- function(plan, grid, tmp) {
  b <- .gd_build_jobs(plan, grid, tmp)
  prof <- .gd_profile()
  .gd_daemon_prep(prof)
  promise <- mirai::mirai_map(unname(b$jobs), .cd_fetch_warp,
                              .args = list(k = b$K), .compute = prof)
  list(info = b$info, promise = promise, t0 = proc.time()[["elapsed"]])
}

# Block on a launched warp, report per-task timing + failures, return `info`
# (keyed by source node id, each with its .bin path). The elapsed clock runs
# from launch, so it includes any work the caller overlapped with the drain.
.gd_warp_collect <- function(launched) {
  info <- launched$info
  progress <- isTRUE(getOption("garry.progress", FALSE))
  r <- launched$promise[]
  t <- proc.time()[["elapsed"]] - launched$t0
  errs <- vapply(r[vapply(r, function(x) inherits(x, "miraiError"), FALSE)],
                 conditionMessage, "")
  if (progress) {
    ok <- Filter(function(x) is.list(x) && !is.null(x$tf), r)
    message(sprintf("[gdal-direct] per-task sums: fetch=%.1fs warp=%.1fs",
                    sum(vapply(ok, function(x) x$tf, 0)),
                    sum(vapply(ok, function(x) x$tw, 0))))
  }
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

# Materialise the per-band results and write the composite GTiff (or return the
# matrices when path is NULL). Shared by the direct and pipeline paths.
.gd_write_result <- function(res, spec, path, nodata) {
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

# Warn on any warp failures in a collected fetch group.
.gd_check_fetch <- function(r, label) {
  errs <- vapply(r[vapply(r, function(x) inherits(x, "miraiError"), FALSE)],
                 conditionMessage, "")
  if (length(errs))
    warning(sprintf("gdal-direct: %d %s warps failed (e.g. %s)",
                    length(errs), label, errs[[1L]]), call. = FALSE)
}

#' Execute a no-focal composite via the lean GDAL-direct cube path.
#' @keywords internal
.execute_composite_direct <- function(plan, spec, path = NULL, nodata = NULL) {
  .require_anvl()
  parallel <- isTRUE(garry_opt("gd_parallel")) && spec$n_bands > 1L
  # Split pool: the fetch-ordered pipeline overlaps the mask + per-band medians
  # with the band fetch on the read pool (only the last band's median is exposed
  # after the drain). A single pool cannot overlap (every daemon is fetching),
  # so it uses the simpler parallel-or-whole-grid path below.
  if (parallel && .gd_pooled())
    return(.execute_composite_pipeline(plan, spec, path, nodata))

  nx <- spec$grid@dims[["x"]]; ny <- spec$grid@dims[["y"]]
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  info <- .gd_warp_sources(plan, spec$grid, tmp)
  bin_of <- function(ids) vapply(ids, function(id) info[[as.character(id)]]$bin, "")
  masked <- length(spec$fmask_srcs) > 0L
  # COMPUTE. Default: one lean whole-grid kernel in this process. Spike
  # (garry.gd_parallel) on a single pool: warm the shared pool, then fan the
  # per-band medians out to it (parallelises across bands).
  tcomp <- system.time({
    if (parallel) {
      mirai::everywhere({
        suppressMessages(library(garry)); try(garry:::.gd_warm(), silent = TRUE)
      }, .compute = "default")
      K2 <- list(chain = lapply(spec$mask_chain, function(n) {
                   n@fn <- .slim_fn(n@fn); n }),
                 F = if (is.null(spec$F)) NULL else .slim_fn(spec$F),
                 op = spec$op, nan_rm = spec$nan_rm, halo = spec$halo,
                 ny = ny, nx = nx, dev = spec$device,
                 fmask_bins = if (masked) bin_of(spec$fmask_srcs) else character(0))
      band_jobs <- lapply(spec$band_srcs, function(ids)
        list(band_bins = bin_of(ids)))
      res <- mirai::mirai_map(band_jobs, .gd_compute_band, .args = list(k = K2),
                              .compute = "default")[]
      bad <- which(vapply(res, function(x) inherits(x, "miraiError"), FALSE))
      if (length(bad))
        stop("gdal-direct parallel compute failed on band ", bad[[1L]], ": ",
             conditionMessage(res[[bad[[1L]]]]), call. = FALSE)
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
  .gd_write_result(res, spec, path, nodata)
}

#' Execute a composite via the split-pool fetch-ordered pipeline.
#'
#' Fetch fmask first on the read pool; compute the cleaned mask on the compute
#' pool while the bands download; then dispatch each band's median as its fetch
#' lands, so band B's median runs while later bands are still fetching. Only the
#' last band's median is exposed after the drain. Requires a garry_daemons split.
#' @keywords internal
.execute_composite_pipeline <- function(plan, spec, path = NULL, nodata = NULL) {
  .require_anvl()
  ny <- spec$grid@dims[["y"]]; nx <- spec$grid@dims[["x"]]
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  progress <- isTRUE(getOption("garry.progress", FALSE))
  masked <- length(spec$fmask_srcs) > 0L
  prof_r <- "garry_read"; prof_c <- "garry_compute"

  b <- .gd_build_jobs(plan, spec$grid, tmp)
  info <- b$info; K <- b$K
  bin_of <- function(ids) vapply(ids, function(id) info[[as.character(id)]]$bin, "")
  fetch <- function(ids) mirai::mirai_map(
    lapply(ids, function(id) b$jobs[[as.character(id)]]),
    .cd_fetch_warp, .args = list(k = K), .compute = prof_r)

  t0 <- proc.time()[["elapsed"]]
  .gd_daemon_prep(prof_r)
  # Dispatch fmask FIRST (it drains before the bands, which queue behind it on
  # the read pool), then the bands. All non-blocking.
  fmask_p <- if (masked) fetch(spec$fmask_srcs) else NULL
  band_p <- lapply(spec$band_srcs, fetch)
  # Warm + attach the compute pool while the read pool fetches (hides cold init).
  mirai::everywhere({
    suppressMessages(library(garry)); try(garry:::.gd_warm(), silent = TRUE)
  }, .compute = prof_c)

  # Mask: once fmask lands, compute the cleaned cube on the compute pool while
  # the bands are still fetching. One mask .bin, read by every band median.
  mask_bin <- file.path(tmp, "mask.bin"); mask_p <- NULL
  if (masked) {
    .gd_check_fetch(fmask_p[], "fmask")
    Km <- list(fmask_bins = bin_of(spec$fmask_srcs), out_bin = mask_bin,
               chain = lapply(spec$mask_chain, function(n) {
                 n@fn <- .slim_fn(n@fn); n }),
               halo = spec$halo, ny = ny, nx = nx, dev = spec$device)
    mask_p <- mirai::mirai(garry:::.gd_compute_mask(km), km = Km, .compute = prof_c)
  }

  # Per-band medians: wait each band's fetch, then dispatch its median (async)
  # so it overlaps the remaining bands' fetches.
  Kb <- list(F = if (is.null(spec$F)) NULL else .slim_fn(spec$F),
             op = spec$op, nan_rm = spec$nan_rm, ny = ny, nx = nx,
             dev = spec$device, mask_bin = if (masked) mask_bin else character(0))
  mask_done <- !masked
  res_p <- vector("list", length(spec$band_srcs))
  for (bi in seq_along(spec$band_srcs)) {
    .gd_check_fetch(band_p[[bi]][], sprintf("band %d", bi))
    if (!mask_done) { mask_p[]; mask_done <- TRUE }   # mask .bin must exist first
    jb <- list(band_bins = bin_of(spec$band_srcs[[bi]]))
    res_p[[bi]] <- mirai::mirai(garry:::.gd_compute_masked_band(jb, kb),
                                jb = jb, kb = Kb, .compute = prof_c)
  }
  if (progress) message(sprintf("[gdal-direct] fetch+dispatch=%.2fs",
                                proc.time()[["elapsed"]] - t0))
  res <- lapply(seq_along(res_p), function(bi) {
    v <- res_p[[bi]][]
    if (inherits(v, "miraiError"))
      stop("gdal-direct pipeline compute failed on band ", bi, ": ",
           conditionMessage(v), call. = FALSE)
    v
  })
  if (progress) message(sprintf("[gdal-direct] pipeline total=%.2fs",
                                proc.time()[["elapsed"]] - t0))
  .gd_write_result(res, spec, path, nodata)
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
