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




# Given a ReduceNode, lift one band's pieces: per-slice band + fmask sources,
# the masked-apply fn F, and the mask CHAIN (Map/Focal nodes, replayed on the
# cube; may include morphology focals). NULL if not reconstructible.
# Structural signature of a mask chain / member fn, for per-slice
# homogeneity checks: the lean kernel lifts F and the mask chain from
# slice 1 and applies them cube-wide, so slices carrying a DIFFERENT
# fn or chain must disqualify the plan (silently computing slice-1
# semantics diverges from execute_plan).
.cd_fn_sig <- function(fn) rlang::hash(serialize(.slim_fn(fn), NULL))

# Per-band read affine for the gd cube path. All slices of a band must
# share one scale/offset (the cube is uploaded and scaled as a unit);
# heterogeneous slices make the fast path ineligible (caller returns
# NULL and the plan falls through to the scheduler, which applies the
# affine per read).
.cd_slice_affine <- function(gg, ids) {
  n1 <- gg(ids[[1L]])
  aff <- list(scale = n1@scale, offset = n1@offset)
  for (id in ids[-1L]) {
    n <- gg(id)
    if (!identical(n@scale, aff$scale) || !identical(n@offset, aff$offset))
      return(NULL)
  }
  aff
}
.cd_chain_sig <- function(chain) {
  rlang::hash(lapply(chain, function(n) list(
    cls = class(n)[[1L]],
    fn = serialize(.slim_fn(n@fn), NULL),
    radius = if (S7::S7_inherits(n, FocalNode)) n@radius else integer(0),
    boundary = if (S7::S7_inherits(n, FocalNode)) n@boundary else character(0),
    weights = if (S7::S7_inherits(n, FocalNode)) n@weights else numeric(0))))
}

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
    # Every slice must be a 2-parent masked MapNode: a stack mixing
    # masked and bare slices is legal IR, and probing it must fall
    # through to the scheduler, not subscript-error out of collect().
    if (!all(vapply(masked, function(id) {
      n <- gg(id)
      S7::S7_inherits(n, MapNode) && length(n@parents) == 2L
    }, logical(1)))) return(NULL)
    band_srcs <- vapply(masked, function(id) gg(id)@parents[[1L]], integer(1))
    if (!all(vapply(band_srcs,
                    function(id) S7::S7_inherits(gg(id), SourceNode), logical(1))))
      return(NULL)
    # Per-slice homogeneity of F.
    f_sig <- .cd_fn_sig(first@fn)
    if (!all(vapply(masked, function(id)
      identical(.cd_fn_sig(gg(id)@fn), f_sig), logical(1)))) return(NULL)
    m0 <- .cd_walk_mask(gg, first@parents[[2L]]); if (is.null(m0)) return(NULL)
    c_sig <- .cd_chain_sig(m0$chain)
    fmask_srcs <- vapply(masked, function(id) {
      w <- .cd_walk_mask(gg, gg(id)@parents[[2L]])
      if (is.null(w) || !identical(.cd_chain_sig(w$chain), c_sig))
        NA_integer_ else w$src
    }, integer(1))
    if (anyNA(fmask_srcs)) return(NULL)
    aff <- .cd_slice_affine(gg, band_srcs)
    if (is.null(aff)) return(NULL)
    # QA sources carry class codes; a scaled mask source is not replayable.
    if (any(vapply(fmask_srcs, function(id) length(gg(id)@scale) == 1L,
                   logical(1)))) return(NULL)
    list(band = band_srcs, fmask = fmask_srcs, F = first@fn,
         mask_chain = m0$chain, halo = m0$halo, op = red@op, nan_rm = red@nan_rm,
         affine = aff)
  } else if (S7::S7_inherits(first, SourceNode)) {
    if (!all(vapply(masked, function(id)
      S7::S7_inherits(gg(id), SourceNode), logical(1)))) return(NULL)
    aff <- .cd_slice_affine(gg, as.integer(masked))
    if (is.null(aff)) return(NULL)
    list(band = as.integer(masked), fmask = integer(0), F = NULL,
         mask_chain = list(), halo = 0L, op = red@op, nan_rm = red@nan_rm,
         affine = aff)
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
  # Smart routing (deep review 2026-08-02): the budget guards the arms
  # that run the whole-grid compute SINGLE-PROCESS in the host (no
  # overlap with the fetch drain) — the single-band kernel, and the
  # multi-band whole-grid kernel when gd_parallel is off. The
  # gd_parallel pipeline needs no guard: it fans the per-band medians
  # across the compute pool RAM-capped, overlapped with the fetches.
  # A heavy plan that falls through lands on the reduce-decomposition
  # route (multi-band) or the scheduler (single-band).
  n_bands <- length(specs); n_slices <- length(s1$band)
  grid_px <- sink@grid@dims[["x"]] * sink@grid@dims[["y"]]
  weight <- (n_bands + (s1$halo > 0L)) * n_slices * grid_px
  if (weight > garry_opt("gd_compute_budget") &&
      (n_bands == 1L || !isTRUE(garry_opt("gd_parallel")))) return(NULL)
  list(op = s1$op, nan_rm = s1$nan_rm, F = s1$F, mask_chain = s1$mask_chain,
       halo = s1$halo, band_srcs = lapply(specs, function(s) s$band),
       band_affine = lapply(specs, function(s) s$affine),
       fmask_srcs = s1$fmask, n_bands = n_bands,
       grid = sink@grid, device = sink@device)
}



# Uniform strip grid for the pipeline's band medians: equal ceiling-height
# body strips plus one remainder, so at most two kernel shapes exist per
# run (anvl's jit cache is shape-keyed). Bounds are c(y0, h), y0 0-based.
.gd_strip_bounds <- function(ny, n_strips) {
  ny <- as.integer(ny)
  ns <- max(1L, min(as.integer(n_strips), ny))
  if (ns == 1L) return(list(c(0L, ny)))
  h <- as.integer(ceiling(ny / ns))
  ns <- as.integer(ceiling(ny / h))
  lapply(seq_len(ns) - 1L, function(i) c(i * h, min(h, ny - i * h)))
}

# Max concurrent band medians whose working sets fit the RAM budget. Each holds
# ~3.5 cubes (band + shared mask + median scratch); cap so their combined
# resident set stays under compute_ram_fraction of AVAILABLE RAM. Clamped to
# [1, pool]; falls back to the full pool when RAM can't be read. This is what
# lets garry_daemons() over-provision compute without OOM on a many-band job.
# With strip decomposition, `ny` is the strip height and `pool` the strip-task
# queue depth, so the cap admits proportionally more, smaller tasks.
.gd_compute_cap <- function(n_slices, ny, nx, pool) {
  pool <- max(1L, as.integer(pool))
  per_task_mb <- 3.5 * n_slices * ny * nx * 4 / 1e6
  avail <- .garry_ram_avail_mb()
  if (is.na(avail) || per_task_mb <= 0) return(pool)
  cap <- floor(garry_opt("compute_ram_fraction") * avail / per_task_mb)
  max(1L, min(pool, as.integer(cap)))
}

# The mirai profile composite_direct dispatches to: the garry_daemons() read
# pool. Distributed execution requires the pools (checked in collect() and
# execute_plan_mirai()), so this is always the read profile.
.gd_profile <- function() "garry_read"

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
         resampling = n@resampling, bin = file.path(tmp, .glue("n{n@id}.bin")))
  })
  names(info) <- vapply(info, function(x) as.character(x$nid), "")
  K <- list(nx = nx, ny = ny,
            gtstr = paste(formatC(grid@transform, format = "g", digits = 10, width = 1),
                          collapse = "/"),
            wkt = gdalraster::srs_to_wkt(cr))
  jobs <- lapply(info, function(x)
    list(locs = .mpc_resign(x$locs), dt = x$dt, nodata = x$nodata,
         resampling = x$resampling, bin = x$bin))
  list(info = info, K = K, jobs = jobs)
}

# Preload garry once per daemon (else fetch tasks cold-init XLA) and set the
# vsicurl/MEM config in the fetch daemons (set_config_option in the host does
# not propagate to mirai daemons).
.gd_daemon_prep <- function(prof) {
  .garry_abi_check(prof)
  .pool_broadcast(quote({
    suppressMessages(library(garry))
    garry::garry_gdal_config()
    options(garry.read_retry = rr)
  }), profiles = prof, rr = garry_opt("read_retry"))
}

# Launch the parallel warp-on-read WITHOUT blocking (raw mirai() per
# source, task fn resolved by name on the daemon). Returns handles to
# collect later, so the caller can warm the compute pool while the
# fetch drains.
.gd_warp_launch <- function(plan, grid, tmp) {
  b <- .gd_build_jobs(plan, grid, tmp)
  prof <- .gd_profile()
  .gd_daemon_prep(prof)
  promise <- lapply(unname(b$jobs), function(j)
    mirai::mirai(garry::.cd_fetch_warp(j, k), j = j, k = b$K,
                 .compute = prof))
  list(info = b$info, promise = promise, t0 = proc.time()[["elapsed"]])
}

# Errors from a collected fetch group: transport failures (miraiError,
# daemon died) AND errors .cd_fetch_warp caught in-task into `$err`.
# The caught kind matters most: the task always writes a complete
# (all-NaN) slice, so without reading `$err` a transient vsicurl/IO
# failure produces a plausible-looking composite with a hole and no
# diagnostic.
.gd_fetch_errs <- function(r) {
  transport <- vapply(r, function(x) inherits(x, "miraiError"), FALSE)
  caught <- vapply(r, function(x)
    is.list(x) && length(x$err) == 1L && !is.na(x$err), FALSE)
  c(vapply(r[transport], conditionMessage, ""),
    vapply(r[caught], function(x) x$err, ""))
}

# Enforce the read-failure contract on a fetch group, matching the
# scheduler: `garry.read_fail = "error"` (the default) aborts the run,
# "nodata" warns and keeps the NaN-filled slices.
.gd_fetch_fail <- function(errs, n, label) {
  if (length(errs) == 0L) return(invisible(NULL))
  msg <- .glue("gdal-direct: {length(errs)}/{n} {label} warps failed ",
               "(e.g. {errs[[1L]]})")
  if (!identical(garry_opt("read_fail"), "nodata"))
    cli::cli_abort(c(msg,
      "i" = paste0("failed slices would read as all-nodata; set ",
                   "options(garry.read_fail = \"nodata\") to accept holes")))
  cli::cli_warn(paste0(msg, "; slices filled with nodata"))
}

# Block on a launched warp, report per-task timing + failures, return `info`
# (keyed by source node id, each with its .bin path). The elapsed clock runs
# from launch, so it includes any work the caller overlapped with the drain.
.gd_warp_collect <- function(launched) {
  info <- launched$info
  progress <- isTRUE(getOption("garry.progress", FALSE))
  r <- lapply(launched$promise, function(h) h[])
  t <- proc.time()[["elapsed"]] - launched$t0
  if (progress) {
    ok <- Filter(function(x) is.list(x) && !is.null(x$tf), r)
    cli::cli_inform(.glue(
      "[gdal-direct] per-task sums: ",
      "fetch={formatC(sum(vapply(ok, function(x) x$tf, 0)), format = 'f', digits = 1)}s ",
      "warp={formatC(sum(vapply(ok, function(x) x$tw, 0)), format = 'f', digits = 1)}s"))
  }
  .gd_fetch_fail(.gd_fetch_errs(r), length(info), "source")
  if (progress) cli::cli_inform(.glue(
    "[gdal-direct] fetch+warp={formatC(t, format = 'f', digits = 2)}s"))
  info
}

# tmpfs dir for a run's per-source .bin payloads.
.gd_tmp <- function() {
  tmp <- file.path(if (dir.exists("/dev/shm")) "/dev/shm" else tempdir(),
                   .glue("gdirect-{Sys.getpid()}"))
  dir.create(tmp); tmp
}

# Materialise the per-band results and write the composite GTiff (or return the
# matrices when path is NULL). Shared by the direct and pipeline paths.
.gd_write_result <- function(res, spec, path, nodata, band_names = NULL,
                             wspec = NULL) {
  mats <- lapply(res, .sv_materialise)                        # one per band
  if (is.null(path)) return(if (spec$n_bands == 1L) mats[[1L]] else mats)
  nd <- if (is.null(nodata)) numeric(0) else nodata
  ds <- gdal_create_output(path, spec$grid, nodata = nd,
                           band_names = band_names, dtype = wspec$dtype,
                           options = wspec$options)
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  for (b in seq_along(mats))
    gdal_write_window(ds, 0L, 0L, mats[[b]], wspec$dtype %||% spec$grid@dtype,
                      nodata = nd, band = b)
  invisible(path)
}

# Surface warp failures (transport AND in-task caught) in a collected
# fetch group under the read-failure contract.
.gd_check_fetch <- function(r, label) {
  .gd_fetch_fail(.gd_fetch_errs(r), length(r), label)
}

#' Execute a no-focal composite via the lean GDAL-direct cube path.
#' @noRd
.execute_composite_direct <- function(plan, spec, path = NULL, nodata = NULL,
                                      band_names = NULL, wspec = NULL) {
  .require_anvl()
  parallel <- isTRUE(garry_opt("gd_parallel")) && spec$n_bands > 1L
  # Split pool: the fetch-ordered pipeline overlaps the mask + per-band medians
  # with the band fetch on the read pool (only the last band's median is exposed
  # after the drain). A single pool cannot overlap (every daemon is fetching),
  # so it uses the simpler parallel-or-whole-grid path below.
  # Parallel multi-band always takes the split-pool pipeline (distributed
  # execution requires garry_daemons(), so the pools are guaranteed here).
  if (parallel)
    return(.execute_composite_pipeline(plan, spec, path, nodata, band_names,
                                       wspec = wspec))

  nx <- spec$grid@dims[["x"]]; ny <- spec$grid@dims[["y"]]
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  info <- .gd_warp_sources(plan, spec$grid, tmp)
  masked <- length(spec$fmask_srcs) > 0L
  # COMPUTE: one lean whole-grid kernel in this process (a single band, or
  # gd_parallel off). The mask (incl. morphology focals) is replayed ONCE on the
  # whole fmask cube, vectorised over time, and shared across bands.
  tcomp <- system.time({
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
    affs <- spec$band_affine
    lean <- function(inp) {
      mask <- if (masked) .gd_replay_mask(inp[[nb + 1L]], chain, halo, nyy, nxx)
              else NULL
      lapply(seq_len(nb), function(b) {
        x <- inp[[b]]
        if (length(affs[[b]]$scale) == 1L)
          x <- x * affs[[b]]$scale + affs[[b]]$offset
        m <- if (masked) F(x, mask) else x
        .apply_reduce(op, m, 1L, nan_rm)
      })
    }
    res <- g_download(g_jit(lean, device = dev)(
      c(band_cubes, if (masked) list(fm) else NULL)))
  })[["elapsed"]]
  if (isTRUE(getOption("garry.progress", FALSE)))
    cli::cli_inform(.glue(
      "[gdal-direct] lean compute={formatC(tcomp, format = 'f', digits = 2)}s"))
  .gd_write_result(res, spec, path, nodata, band_names, wspec = wspec)
}

#' Execute a composite via the split-pool fetch-ordered pipeline.
#'
#' Fetch fmask first on the read pool; compute the cleaned mask on the compute
#' pool while the bands download; then dispatch each band's median as its fetch
#' lands, so band B's median runs while later bands are still fetching. Only the
#' last band's median is exposed after the drain. Requires a garry_daemons split.
#' @noRd
.execute_composite_pipeline <- function(plan, spec, path = NULL, nodata = NULL,
                                        band_names = NULL, wspec = NULL) {
  .require_anvl()
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  .gd_write_result(.gd_reduce_results(plan, spec, tmp), spec, path, nodata, band_names, wspec = wspec)
}

# The fetch-ordered per-band compute of the composite pipeline, factored out so
# the reduce-decomposition path can reuse it: fetch fmask first, compute the
# cleaned mask on the compute pool while the bands download, then dispatch each
# band's reduce as its fetch lands (overlapped, RAM-capped). Returns the list of
# per-band raw f32 payloads (band-source order); the caller writes or feeds them
# to an upper kernel. `tmp` is caller-owned (shared across groups).
.gd_reduce_results <- function(plan, spec, tmp) {
  ny <- spec$grid@dims[["y"]]; nx <- spec$grid@dims[["x"]]
  progress <- isTRUE(getOption("garry.progress", FALSE))
  masked <- length(spec$fmask_srcs) > 0L
  prof_r <- "garry_read"
  # Compute dispatch rides the profile set (one legacy pool, or N
  # routed width-1 profiles): warm every profile, round-robin the
  # mask/band jobs across them.
  comp_profs <- .comp_profiles()
  cp_i <- 0L
  next_cp <- function() {
    cp_i <<- cp_i + 1L
    comp_profs[[1L + (cp_i - 1L) %% length(comp_profs)]]
  }

  b <- .gd_build_jobs(plan, spec$grid, tmp)
  info <- b$info; K <- b$K
  bin_of <- function(ids) vapply(ids, function(id) info[[as.character(id)]]$bin, "")
  # Raw mirai() per job with the task fn resolved BY NAME on the daemon
  # (garry::), the same pattern as the scheduler's launch functions.
  # mirai_map() ships the function object inside every task's .args;
  # measured on this pipeline that per-task overhead inflates from
  # ~6 ms (idle pool) to ~100 ms once the read daemons are busy with
  # live warps, serialising a 220-task dispatch into ~25 s of host
  # stall that delayed every downstream phase (the "slow lead-in").
  fetch <- function(ids) lapply(ids, function(id)
    mirai::mirai(garry::.cd_fetch_warp(j, k),
                 j = b$jobs[[as.character(id)]], k = K,
                 .compute = prof_r))

  t0 <- proc.time()[["elapsed"]]
  .gd_daemon_prep(prof_r)
  # Dispatch fmask FIRST (it drains before the bands, which queue behind it on
  # the read pool), then the bands. All non-blocking.
  fmask_p <- if (masked) fetch(spec$fmask_srcs) else NULL
  band_p <- lapply(spec$band_srcs, fetch)
  # Kernel identity for the lean band kernel: everything the traced
  # closure closes over (slimmed F, op, nan_rm, affine, masked, device).
  # Affine varies per band, so bands sharing an affine share a ck — and
  # with it one JitFunction per daemon (see .gd_cached_jit): without the
  # key, every band task rebuilt its dispatcher and recompiled.
  Fs <- if (is.null(spec$F)) NULL else .slim_fn(spec$F)
  base_sig <- rlang::hash(list(
    fn = if (is.null(Fs)) NULL else serialize(Fs, NULL),
    op = spec$op, nan_rm = spec$nan_rm, masked = masked, dev = spec$device))
  band_ck <- vapply(seq_along(spec$band_srcs), function(bi)
    rlang::hash(list(base_sig, spec$band_affine[[bi]])), "")

  # Strip grid: spread each band's median across the pool so the exposed
  # drain (the bands with no fetch left to hide behind) divides by the
  # pool width instead of landing whole on one daemon.
  ns_opt <- as.integer(garry_opt("gd_strips"))
  bounds <- .gd_strip_bounds(ny, if (ns_opt >= 1L) ns_opt else max(1L, .comp_n()))
  ns <- length(bounds)

  # Warm + attach the compute pool while the read pool fetches: hide the
  # XLA client cold init AND the lean kernels' compiles (one per distinct
  # ck, executed per strip height on zero-byte g_fill dummies) inside the
  # fetch window, so no post-drain strip pays a compile.
  hs <- unique(vapply(bounds, `[[`, integer(1), 2L))
  wsp <- unname(lapply(which(!duplicated(band_ck)), function(bi)
    list(ck = band_ck[[bi]], F = Fs, op = spec$op, nan_rm = spec$nan_rm,
         affine = spec$band_affine[[bi]], masked = masked, dev = spec$device,
         n = length(spec$band_srcs[[bi]]), hs = hs, nx = nx)))
  for (p in comp_profs)
    mirai::everywhere({
      suppressMessages(library(garry))
      try(garry::.gd_warm_pipeline(sp), silent = TRUE)
    }, sp = wsp, .compute = p)

  # Mask: once fmask lands, compute the cleaned cube on the compute pool while
  # the bands are still fetching. One mask .bin, read by every band median.
  mask_bin <- tempfile("mask", tmpdir = tmp, fileext = ".bin"); mask_p <- NULL
  if (masked) {
    fmr <- lapply(fmask_p, function(h) h[])
    .gd_check_fetch(fmr, "fmask")
    if (progress) cli::cli_inform(.glue(
      "[gdal-direct] fmask ",
      "drain={formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s ",
      "({length(fmr)} tasks, warp ",
      "sum={formatC(sum(vapply(fmr, function(r) r$tw, 0)), format = 'f', digits = 1)}s)"))
    Km <- list(fmask_bins = bin_of(spec$fmask_srcs), out_bin = mask_bin,
               chain = lapply(spec$mask_chain, function(n) {
                 n@fn <- .slim_fn(n@fn); n }),
               halo = spec$halo, ny = ny, nx = nx, dev = spec$device,
               ck = rlang::hash(list(chain = .cd_chain_sig(spec$mask_chain),
                                     halo = spec$halo, ny = ny, nx = nx,
                                     dev = spec$device)))
    mask_p <- mirai::mirai(garry::.gd_compute_mask(km), km = Km,
                           .compute = next_cp())
  }

  # Per-band medians, strip-decomposed: wait each band's fetch, then dispatch
  # its strips (async, round-robin across the profiles) so they overlap the
  # remaining bands' fetches -- but never let more than `cap` strip tasks be
  # in flight, so the executing working sets stay under the RAM budget (a
  # generous / many-band pool then drains in memory-bounded waves, not a
  # spike). Strips reassemble by raw concatenation in y order: the payloads
  # are row-major f32, so the result is byte-identical to a whole-band job.
  Kb <- list(F = Fs, op = spec$op, nan_rm = spec$nan_rm, ny = ny, nx = nx,
             dev = spec$device, mask_bin = if (masked) mask_bin else character(0))
  n_slices <- length(spec$band_srcs[[1L]])
  cap <- .gd_compute_cap(n_slices, bounds[[1L]][[2L]], nx,
                         2L * max(1L, .comp_n()))
  nb <- length(spec$band_srcs)
  if (progress && cap < nb * ns)
    cli::cli_inform(.glue(
      "[gdal-direct] compute in-flight capped at {cap} strip task(s) (RAM budget)"))
  mask_done <- !masked
  res_p <- new.env(parent = emptyenv())
  parts <- lapply(seq_len(nb), function(i) vector("list", ns))
  got <- integer(nb)
  res <- vector("list", nb)
  t_comp <- 0; jit_creates <- 0L
  inflight <- list()                          # dispatched, not yet collected (FIFO)
  harvest <- function() {
    it <- inflight[[1L]]; inflight <<- inflight[-1L]
    v <- res_p[[it$key]][]
    if (inherits(v, "miraiError"))
      cli::cli_abort(paste0(
        "gdal-direct pipeline compute failed on band {it$bi} strip {it$si}: ",
        "{conditionMessage(v)}"))
    t_comp <<- t_comp + (attr(v, "gd_t") %||% 0)
    jit_creates <<- jit_creates + (attr(v, "gd_jit") %||% 0L)
    attr(v, "gd_t") <- NULL; attr(v, "gd_jit") <- NULL
    rm(list = it$key, envir = res_p)
    parts[[it$bi]][[it$si]] <<- v
    got[[it$bi]] <<- got[[it$bi]] + 1L
    if (got[[it$bi]] == ns) {
      res[[it$bi]] <<- if (ns == 1L) parts[[it$bi]][[1L]] else {
        p <- do.call(c, lapply(parts[[it$bi]], function(x) {
          attributes(x) <- NULL; x }))
        attr(p, "gdim") <- c(ny, nx); attr(p, "gdt") <- "f32"
        p
      }
      parts[[it$bi]] <<- list()
    }
  }
  for (bi in seq_len(nb)) {
    bres <- lapply(band_p[[bi]], function(h) h[])
    .gd_check_fetch(bres, .glue("band {bi}"))
    if (progress) cli::cli_inform(.glue(
      "[gdal-direct] band {bi} drained at ",
      "{formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s"))
    if (!mask_done) { mask_p[]; mask_done <- TRUE }   # mask .bin must exist first
    for (si in seq_len(ns)) {
      while (length(inflight) >= cap) harvest()       # RAM cap: bound concurrency
      jb <- list(band_bins = bin_of(spec$band_srcs[[bi]]),
                 affine = spec$band_affine[[bi]],
                 rows = if (ns == 1L) NULL else bounds[[si]],
                 ck = band_ck[[bi]])
      key <- .glue("b{bi}.s{si}")
      res_p[[key]] <- mirai::mirai(garry::.gd_compute_masked_band(jb, kb),
                                   jb = jb, kb = Kb, .compute = next_cp())
      inflight[[length(inflight) + 1L]] <- list(bi = bi, si = si, key = key)
    }
  }
  if (progress) cli::cli_inform(.glue(
    "[gdal-direct] fetch+dispatch=",
    "{formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s"))
  while (length(inflight)) harvest()
  if (progress) cli::cli_inform(.glue(
    "[gdal-direct] pipeline ",
    "total={formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s ",
    "(compute sum={formatC(t_comp, format = 'f', digits = 2)}s, ",
    "{ns} strip/band, {jit_creates} post-warm compile)"))
  res
}

# ---------------------------------------------------------------------------
# General warp-on-read executor: the single path for any warp-on-read-eligible
# plan (arbitrary Source/Map/Focal/Stack/Reduce IR over GTI sources). Warps
# every source (overview-aware, on the read pool), then compiles the WHOLE
# reachable IR into ONE jit via .compose_stage_fn -- so derived bands, band
# math, and nested reduce -> map -> reduce pipelines all run fused, regardless
# of shape. .cd_spec (the fetch-ordered composite pipeline) is tried first as a
# throughput optimisation for the pure composite; this covers everything else
# that reads warp-on-read. Whole-grid (fits in memory); spatial chunking for
# scale is the next stage.
# ---------------------------------------------------------------------------

#' Recognise any warp-on-read-replayable plan and lift its whole IR, or NULL.
#' @noRd
.gd_spec <- function(plan) {
  if (!isTRUE(garry_opt("composite_direct"))) return(NULL)
  if (!.g_has_raw_upload()) return(NULL)
  graph <- plan@graph
  sink <- plan@stages[[plan@sink]]
  if (sink@kind != "compute") return(NULL)          # raster (compute) sink only
  src_stages <- Filter(function(s) s@kind == "source_read", plan@stages)
  if (!length(src_stages)) return(NULL)
  for (s in src_stages) {                            # every source must be fetchable
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
  if (!all(input_nodes %in% src_ids)) return(NULL)
  members <- ids[!is_src]
  list(members = members, input_nodes = input_nodes, sink_out = sink_out,
       halo = .stage_halo(graph, members, input_nodes),
       grid = sink@grid, device = sink@device)
}

#' Execute any warp-on-read plan via whole-IR replay in one jit.
#' @noRd
.execute_gd_general <- function(plan, gspec, path = NULL, nodata = NULL,
                                band_names = NULL, wspec = NULL) {
  .require_anvl()
  graph <- plan@graph
  nx <- gspec$grid@dims[["x"]]; ny <- gspec$grid@dims[["y"]]
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  info <- .gd_warp_sources(plan, gspec$grid, tmp)   # overview-aware, on the read pool

  tcomp <- system.time({
    dev <- .exec_device(gspec$device)
    h <- gspec$halo
    fn <- .compose_stage_fn(graph, gspec$members, gspec$input_nodes,
                            list(gspec$sink_out), h)
    inputs <- lapply(gspec$input_nodes, function(id) {
      a <- g_upload_raw(readBin(info[[as.character(id)]]$bin, "raw",
                                n = ny * nx * 4L), "f32", c(ny, nx), device = dev)
      n <- graph_get(graph, id)
      if (length(n@scale) == 1L) a <- a * n@scale + n@offset
      if (h > 0L) g_pad(a, h, NaN) else a          # radius-cell NaN edge boundary
    })
    res <- g_download(g_jit(fn, device = dev)(inputs))[[.key(gspec$sink_out)]]
  })[["elapsed"]]
  if (isTRUE(getOption("garry.progress", FALSE)))
    cli::cli_inform(.glue(
      "[gdal-direct] general compute={formatC(tcomp, format = 'f', digits = 2)}s"))

  m <- .sv_materialise(res)
  d <- dim(m)
  nb <- if (length(d) == 3L) d[[1L]] else 1L
  mats <- if (length(d) == 3L) lapply(seq_len(nb), function(b) m[b, , ]) else list(m)
  if (is.null(path)) return(if (nb == 1L) mats[[1L]] else mats)
  wnodata <- if (is.null(nodata)) numeric(0) else nodata
  ds <- gdal_create_output(path, gspec$grid, nodata = wnodata,
                           band_names = band_names, dtype = wspec$dtype,
                           options = wspec$options)
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  for (b in seq_len(nb))
    gdal_write_window(ds, 0L, 0L, mats[[b]],
                      wspec$dtype %||% gspec$grid@dtype,
                      nodata = wnodata, band = b)
  invisible(path)
}

# ---------------------------------------------------------------------------
# Reduce-decomposition: the single general path for any reduce-structured graph.
#
# The expensive work in every plan is the temporal reduces over source cubes
# (collapsing many slices to 2D). The composite pipeline computes those fastest,
# because it overlaps each band's reduce with the next band's fetch. This path
# lifts that: find the LEAF temporal reduces (a reduce over "t" with no reduce
# below it), group those sharing a mask/op into composite specs, compute each
# group via the overlapped per-band pipeline, then run the REST of the graph
# (maps, focals, reduces over small axes) on the materialised 2D results in one
# lean kernel. ndvi (map over two composites), nested reduce->map->reduce, and
# deep 10-year composite->ndvi->slope pipelines all reduce to this shape.
#
# Byte-identical to the whole-grid .execute_gd_general: each leaf reduce yields
# the same 2D result whether computed whole-grid or via the pipeline, and the
# upper kernel is the same nodes .compose_stage_fn would run whole-grid. The
# only round-trip is materialising each leaf reduce to an f32 matrix and
# re-uploading it (f32 -> double -> f32 is exact), so the upper maths is bit-
# identical.
# ---------------------------------------------------------------------------

.gd_hash <- function(x) {
  tf <- tempfile(); on.exit(unlink(tf), add = TRUE)
  writeBin(serialize(x, NULL), tf); unname(tools::md5sum(tf))
}

#' Recognise a reduce-decomposable plan and lift its groups + upper IR, or NULL.
#'
#' NULL when there is no upper IR (a pure composite -> `.cd_spec`), when a leaf
#' reduce is not composite-reducible, or when the upper IR does not close over
#' the leaf reduces (a node consuming a raw source alongside a reduce -> the
#' scheduler). `.gd_spec` gates fetchability and the node-type whitelist.
#' @noRd
.gd_decompose <- function(plan) {
  gsp <- .gd_spec(plan)                       # fetchable GTI + Source/Map/Focal/Stack/Reduce
  if (is.null(gsp)) return(NULL)
  graph <- plan@graph
  gg <- function(id) graph_get(graph, id)
  sink_out <- gsp$sink_out
  ids <- .reachable(graph, sink_out)
  is_red_t <- function(n) S7::S7_inherits(n, ReduceNode) && "t" %in% n@over
  # Leaf temporal reduces: a reduce over t with no reduce anywhere below it.
  leaf_ids <- Filter(function(id) {
    if (!is_red_t(gg(id))) return(FALSE)
    below <- setdiff(.reachable(graph, id), id)
    !any(vapply(below, function(s) is_red_t(gg(s)), logical(1)))
  }, ids)
  if (!length(leaf_ids)) return(NULL)
  specs <- lapply(leaf_ids, function(id) .cd_reduce_spec(gg, gg(id)))
  if (any(vapply(specs, is.null, logical(1)))) return(NULL)

  # Upper IR: nodes strictly above the leaf reduces (their subtrees are the
  # inputs). No upper members -> pure composite, not our job.
  subtrees <- unique(unlist(lapply(leaf_ids, function(id) .reachable(graph, id))))
  members <- setdiff(ids, subtrees)           # ascending == topo
  if (!length(members)) return(NULL)
  # Every upper member's parents must resolve to an upper member or a leaf
  # reduce (else a raw non-reduced source feeds the upper IR -> scheduler).
  leaf_set <- unlist(leaf_ids)
  ok <- all(vapply(members, function(id)
    all(gg(id)@parents %in% c(members, leaf_set)), logical(1)))
  if (!ok) return(NULL)

  # Group leaf reduces that form ONE composite (shared mask/op) -> one pipeline
  # call computes them as a multi-band composite with fetch overlap.
  gkey <- vapply(seq_along(specs), function(i) {
    s <- specs[[i]]
    paste(s$op, s$nan_rm, s$halo, paste(s$fmask, collapse = ","),
          .gd_hash(list(lapply(s$mask_chain, function(n) { n@fn <- .slim_fn(n@fn); n }),
                        if (is.null(s$F)) NULL else .slim_fn(s$F))), sep = "#")
  }, "")
  groups <- lapply(unique(gkey), function(k) {
    idx <- which(gkey == k); ss <- specs[idx]; s1 <- ss[[1L]]
    list(reduce_ids = unlist(leaf_ids[idx]),
         spec = list(op = s1$op, nan_rm = s1$nan_rm, F = s1$F,
                     mask_chain = s1$mask_chain, halo = s1$halo,
                     band_srcs = lapply(ss, function(s) s$band),
                     band_affine = lapply(ss, function(s) s$affine),
                     fmask_srcs = s1$fmask, n_bands = length(ss),
                     grid = gsp$grid, device = gsp$device))
  })
  list(groups = groups,
       upper = list(members = members, input_nodes = leaf_set, sink_out = sink_out,
                    halo = .stage_halo(graph, members, leaf_set),
                    grid = gsp$grid, device = gsp$device))
}

#' Execute a reduce-decomposable plan: overlap-compute the leaf reduces, then
#' run the upper IR on the materialised results.
#' @noRd
.execute_gd_reduce <- function(plan, decomp, path = NULL, nodata = NULL,
                               band_names = NULL, wspec = NULL) {
  .require_anvl()
  graph <- plan@graph
  tmp <- .gd_tmp(); on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  u <- decomp$upper
  dev <- .exec_device(u$device); h <- u$halo

  # 1. Each group's leaf reduces via the overlapped per-band pipeline, keyed by
  #    reduce node id (band-source order == reduce_ids order).
  leaf <- new.env(parent = emptyenv())
  for (grp in decomp$groups) {
    res <- .gd_reduce_results(plan, grp$spec, tmp)
    mats <- lapply(res, .sv_materialise)
    for (i in seq_along(grp$reduce_ids))
      leaf[[.key(grp$reduce_ids[[i]])]] <- mats[[i]]
  }

  # 2. Upper IR on the materialised 2D leaf results, one lean kernel.
  tcomp <- system.time({
    fn <- .compose_stage_fn(graph, u$members, u$input_nodes, list(u$sink_out), h)
    inputs <- lapply(u$input_nodes, function(id) {
      a <- g_upload(leaf[[.key(id)]], "f32", device = dev)
      if (h > 0L) g_pad(a, h, NaN) else a
    })
    res <- g_download(g_jit(fn, device = dev)(inputs))[[.key(u$sink_out)]]
  })[["elapsed"]]
  if (isTRUE(getOption("garry.progress", FALSE)))
    cli::cli_inform(.glue(
      "[gdal-direct] upper compute={formatC(tcomp, format = 'f', digits = 2)}s"))

  m <- .sv_materialise(res); d <- dim(m)
  nb <- if (length(d) == 3L) d[[1L]] else 1L
  mats <- if (length(d) == 3L) lapply(seq_len(nb), function(b) m[b, , ]) else list(m)
  if (is.null(path)) return(if (nb == 1L) mats[[1L]] else mats)
  wnodata <- if (is.null(nodata)) numeric(0) else nodata
  ds <- gdal_create_output(path, u$grid, nodata = wnodata,
                           band_names = band_names, dtype = wspec$dtype,
                           options = wspec$options)
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  for (b in seq_len(nb))
    gdal_write_window(ds, 0L, 0L, mats[[b]], wspec$dtype %||% u$grid@dtype,
                      nodata = wnodata, band = b)
  invisible(path)
}

