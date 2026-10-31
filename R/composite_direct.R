#' @include passes.R gdal_adapter.R ops.R scheduler.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# GDAL-direct temporal-composite fast path.
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
# Gated by options(garry.composite_direct = TRUE); requires the daemon pools.
# Non-matching plans fall through to the scheduler (`.cd_spec` returns NULL).
# ---------------------------------------------------------------------------

# Walk a LINEAR mask chain (Map/Focal nodes) from `mid` back to its SourceNode.
# Returns list(chain = source->mask order, src = fmask source id, halo = sum of
# focal radii) or NULL if the chain branches or hits an unsupported node.
.cd_walk_mask <- function(gg, mid) {
  chain <- list()
  h <- 0L
  cur <- gg(mid)
  while (!S7::S7_inherits(cur, SourceNode)) {
    if (
      !(S7::S7_inherits(cur, MapNode) || S7::S7_inherits(cur, FocalNode)) ||
        length(cur@parents) != 1L
    ) {
      return(NULL)
    }
    if (S7::S7_inherits(cur, FocalNode)) {
      h <- h + cur@radius
    }
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
.gd_replay_mask <- function(fm, chain, halo) {
  mc <- g_pad(fm, halo, NaN)
  for (node in chain) {
    mc <- .g_as_declared(.eval_node(node, list(mc), NULL), node@grid@dtype)
  }
  mc
}

# Structural signature of a mask chain / member fn, for per-slice
# homogeneity checks: the lean kernel lifts F and the mask chain from
# slice 1 and applies them cube-wide, so slices carrying a DIFFERENT
# fn or chain must disqualify the plan (silently computing slice-1
# semantics diverges from execute_plan).
.cd_fn_sig <- function(fn) rlang::hash(.fn_identity(fn))

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
    if (!identical(n@scale, aff$scale) || !identical(n@offset, aff$offset)) {
      return(NULL)
    }
  }
  aff
}
.cd_chain_sig <- function(chain) {
  rlang::hash(lapply(chain, function(n) {
    list(
      cls = class(n)[[1L]],
      fn = .fn_identity(n@fn),
      radius = if (S7::S7_inherits(n, FocalNode)) n@radius else integer(0),
      weights = if (S7::S7_inherits(n, FocalNode)) n@weights else numeric(0)
    )
  }))
}

# The slice label a GTI source's open options select: NA without a FILTER,
# the label for exactly FILTER=slice = '<label>', and NULL for any other
# filter, which only GDAL can evaluate.
.gti_slice_of <- function(oo) {
  f <- grep("^FILTER=", oo, value = TRUE)
  if (!length(f)) {
    return(NA_character_)
  }
  m <- regmatches(f, regexec("^FILTER=slice = '([^']*)'$", f))[[1L]]
  if (length(f) != 1L || length(m) != 2L) {
    return(NULL)
  }
  m[[2L]]
}

# Can the warp-on-read routes read this GTI source themselves? They pick a
# slice's items from the index sidecar and draw them in ascending datetime
# order, reading one band into f32 buffers; any other filter, sort order,
# band selection or dtype f32 does not hold is left to GDAL's GTI driver
# on the scheduler.
.gd_source_ok <- function(n) {
  if (
    length(n@path) != 1L ||
      !grepl("^GTI:", n@path) ||
      length(n@band) != 1L ||
      !n@grid@dtype %in% .f32_exact_dtypes
  ) {
    return(FALSE)
  }
  meta <- .gti_meta(n@path)
  sl <- .gti_slice_of(n@open_options)
  if (is.null(meta) || is.null(sl)) {
    return(FALSE)
  }
  if (!is.na(sl) && !"slice" %in% names(meta$entries)) {
    return(FALSE)
  }
  opt <- function(key) {
    v <- grep(paste0("^", key, "="), n@open_options, value = TRUE)
    if (length(v)) sub("^[^=]*=", "", v[[1L]]) else NA_character_
  }
  sf <- opt("SORT_FIELD")
  asc <- opt("SORT_FIELD_ASC")
  (is.na(sf) || identical(sf, "datetime")) && (is.na(asc) || toupper(asc) == "YES")
}

# Given a ReduceNode, lift one band's pieces: per-slice band + fmask sources,
# the masked-apply fn F, and the mask CHAIN (Map/Focal nodes, replayed on the
# cube; may include morphology focals). NULL if not reconstructible.
.cd_reduce_spec <- function(gg, red) {
  if (!S7::S7_inherits(red, ReduceNode)) {
    return(NULL)
  }
  if (
    !("t" %in% red@over) ||
      !(red@op %in% c("median", "mean", "min", "max", "sum"))
  ) {
    return(NULL)
  }
  if (length(red@parents) != 1L) {
    return(NULL)
  }
  stk <- gg(red@parents[[1L]])
  if (!S7::S7_inherits(stk, StackNode) || !length(stk@parents)) {
    return(NULL)
  }
  masked <- stk@parents
  first <- gg(masked[[1L]])
  if (S7::S7_inherits(first, MapNode)) {
    # Every slice must be a 2-parent masked MapNode: a stack mixing
    # masked and bare slices is legal IR, and probing it must fall
    # through to the scheduler, not subscript-error out of collect().
    if (
      !all(vapply(
        masked,
        function(id) {
          n <- gg(id)
          S7::S7_inherits(n, MapNode) && length(n@parents) == 2L
        },
        logical(1)
      ))
    ) {
      return(NULL)
    }
    band_srcs <- vapply(masked, function(id) gg(id)@parents[[1L]], integer(1))
    if (
      !all(vapply(
        band_srcs,
        function(id) S7::S7_inherits(gg(id), SourceNode),
        logical(1)
      ))
    ) {
      return(NULL)
    }
    # Per-slice homogeneity of F.
    f_sig <- .cd_fn_sig(first@fn)
    if (
      !all(vapply(
        masked,
        function(id) {
          identical(.cd_fn_sig(gg(id)@fn), f_sig)
        },
        logical(1)
      ))
    ) {
      return(NULL)
    }
    m0 <- .cd_walk_mask(gg, first@parents[[2L]])
    if (is.null(m0)) {
      return(NULL)
    }
    c_sig <- .cd_chain_sig(m0$chain)
    fmask_srcs <- vapply(
      masked,
      function(id) {
        w <- .cd_walk_mask(gg, gg(id)@parents[[2L]])
        if (is.null(w) || !identical(.cd_chain_sig(w$chain), c_sig)) {
          NA_integer_
        } else {
          w$src
        }
      },
      integer(1)
    )
    if (anyNA(fmask_srcs)) {
      return(NULL)
    }
    aff <- .cd_slice_affine(gg, band_srcs)
    if (is.null(aff)) {
      return(NULL)
    }
    # QA sources carry class codes; a scaled mask source is not replayable.
    if (
      any(vapply(
        fmask_srcs,
        function(id) length(gg(id)@scale) == 1L,
        logical(1)
      ))
    ) {
      return(NULL)
    }
    list(
      band = band_srcs,
      fmask = fmask_srcs,
      F = first@fn,
      mask_chain = m0$chain,
      halo = m0$halo,
      op = red@op,
      nan_rm = red@nan_rm,
      affine = aff
    )
  } else if (S7::S7_inherits(first, SourceNode)) {
    if (
      !all(vapply(
        masked,
        function(id) {
          S7::S7_inherits(gg(id), SourceNode)
        },
        logical(1)
      ))
    ) {
      return(NULL)
    }
    aff <- .cd_slice_affine(gg, as.integer(masked))
    if (is.null(aff)) {
      return(NULL)
    }
    list(
      band = as.integer(masked),
      fmask = integer(0),
      F = NULL,
      mask_chain = list(),
      halo = 0L,
      op = red@op,
      nan_rm = red@nan_rm,
      affine = aff
    )
  } else {
    NULL
  }
}

# Bands (+1 with morphology) x slices x grid pixels past which a whole-grid
# kernel in the host loses to the scheduler's overlapped parallel compute.
# About the 3-band morphology crossover.
.gd_compute_budget <- 2.2e8

# The source_read stages of a plan the warp-on-read routes may take: a
# compute sink, and every source one they can read themselves (so its
# items can be fetched locally). Intermediate compute stages are fine: the
# routes recompute from the sources however the planner split the graph
# (e.g. a shared mask materialised on its own). NULL for any other plan.
.gd_source_stages <- function(plan) {
  if (!isTRUE(garry_opt("composite_direct"))) {
    return(NULL)
  }
  if (plan@stages[[plan@sink]]@kind != "compute") {
    return(NULL)
  }
  src_stages <- Filter(function(s) s@kind == "source_read", plan@stages)
  for (s in src_stages) {
    if (!.gd_source_ok(graph_get(plan@graph, s@members[[1L]]))) {
      return(NULL)
    }
  }
  if (length(src_stages)) src_stages
}

# Recognise the reconstructible composite shape and lift its pieces, or NULL.
# Shape: N GTI source_reads feeding ONE fused compute sink whose output is either
# a single ReduceNode over "t" (single band) or a StackNode along "band" over one
# ReduceNode per band (multi-band, sharing one mask). Each ReduceNode is fed by a
# StackNode of homogeneous per-slice masked MapNodes (F) over (band SourceNode,
# mask MapNode (M) over fmask SourceNode) -- or bare SourceNodes when unmasked.
.cd_spec <- function(plan) {
  src_stages <- .gd_source_stages(plan)
  if (is.null(src_stages)) {
    return(NULL)
  }
  graph <- plan@graph
  sink <- plan@stages[[plan@sink]]
  gg <- function(id) graph_get(graph, id)
  src_ids <- vapply(src_stages, function(s) gg(s@members[[1L]])@id, integer(1))
  top <- gg(sink@members[[length(sink@members)]]) # the sink's output node
  if (S7::S7_inherits(top, ReduceNode)) {
    reduces <- list(top)
  } else if (S7::S7_inherits(top, StackNode) && identical(top@along, "band")) {
    reduces <- lapply(top@parents, gg)
  } else {
    return(NULL)
  }

  specs <- lapply(reduces, function(r) .cd_reduce_spec(gg, r))
  if (any(vapply(specs, is.null, logical(1)))) {
    return(NULL)
  }
  # every band/fmask leaf must be a fetchable source_read source
  leaves <- unlist(lapply(specs, function(s) c(s$band, s$fmask)))
  if (!all(leaves %in% src_ids)) {
    return(NULL)
  }
  s1 <- specs[[1L]]
  # The route computes every band with band 1's per-slice fn, mask chain
  # and mask sources, so every band must share them; anything else falls
  # through to the reduce decomposition, which groups by fn and chain.
  if (length(unique(vapply(specs, .cd_group_key, ""))) > 1L) {
    return(NULL)
  }
  # Smart routing (deep review 2026-08-02): a single band runs its
  # whole-grid kernel SINGLE-PROCESS in the host, with no overlap with
  # the fetch drain, so a heavy one is left to the scheduler. The
  # multi-band pipeline needs no guard: it fans the per-band medians
  # across the compute pool RAM-capped, overlapped with the fetches.
  n_bands <- length(specs)
  # in double: GridSpec dims are integer and the product passes 2^31
  grid_px <- as.numeric(sink@grid@dims[["x"]]) * sink@grid@dims[["y"]]
  weight <- (1L + (s1$halo > 0L)) * length(s1$band) * grid_px
  if (n_bands == 1L && weight > .gd_compute_budget) {
    return(NULL)
  }
  .cd_group_spec(specs, sink@grid, sink@device)
}

# What makes per-band specs one composite: the same op, mask sources,
# mask chain and per-slice fn.
.cd_group_key <- function(s) {
  paste(
    s$op,
    s$nan_rm,
    s$halo,
    paste(s$fmask, collapse = ","),
    .cd_chain_sig(s$mask_chain),
    .cd_fn_sig(s$F),
    sep = "#"
  )
}

# The composite of per-band specs that share one key.
.cd_group_spec <- function(specs, grid, device) {
  s1 <- specs[[1L]]
  list(
    op = s1$op,
    nan_rm = s1$nan_rm,
    F = s1$F,
    mask_chain = s1$mask_chain,
    halo = s1$halo,
    band_srcs = lapply(specs, function(s) s$band),
    band_affine = lapply(specs, function(s) s$affine),
    fmask_srcs = s1$fmask,
    n_bands = length(specs),
    grid = grid,
    device = device
  )
}


# Uniform strip grid for the pipeline's band medians: equal ceiling-height
# body strips plus one remainder, so at most two kernel shapes exist per
# run (anvl's jit cache is shape-keyed). Bounds are c(y0, h), y0 0-based.
.gd_strip_bounds <- function(ny, n_strips) {
  ny <- as.integer(ny)
  ns <- max(1L, min(as.integer(n_strips), ny))
  if (ns == 1L) {
    return(list(c(0L, ny)))
  }
  h <- as.integer(ceiling(ny / ns))
  ns <- as.integer(ceiling(ny / h))
  lapply(seq_len(ns) - 1L, function(i) c(i * h, min(h, ny - i * h)))
}

# Max concurrent band medians whose working sets fit the RAM budget. Each holds
# ~3.5 cubes (band + shared mask + median scratch); cap so their combined
# resident set stays under exec_ram_fraction of AVAILABLE RAM. Clamped to
# [1, pool], the full pool when RAM can't be read, which
# .garry_ram_avail_mb() warns of. This is what lets garry_daemons()
# over-provision compute without OOM on a many-band job.
# With strip decomposition, `ny` is the strip height and `pool` the strip-task
# queue depth, so the cap admits proportionally more, smaller tasks.
.gd_strip_mb <- function(n_slices, ny, nx) 3.5 * n_slices * ny * nx * 4 / 2^20

.gd_compute_cap <- function(n_slices, ny, nx, pool) {
  pool <- max(1L, as.integer(pool))
  per_task_mb <- .gd_strip_mb(n_slices, ny, nx)
  avail <- .garry_ram_avail_mb()
  if (is.na(avail) || per_task_mb <= 0) {
    return(pool)
  }
  cap <- floor(garry_opt("exec_ram_fraction") * avail / per_task_mb)
  max(1L, min(pool, as.integer(cap)))
}

# Fetch each GTI source's slice items and warp its f32 pixels straight into a
# per-source .bin on tmpfs (parallel across the pool), and report the timing.
# Returns the jobs: keyed by source node id, each with its .bin path. `grid`
# supplies the spatial target (nx/ny/transform/crs); every source is pinned to
# it.
.gd_warp_sources <- function(plan, grid, tmp, tl) {
  b <- .gd_build_jobs(plan, grid, tmp)
  .gd_daemon_prep("garry_read")
  t0 <- proc.time()[["elapsed"]]
  r <- .gd_fetch_land(tl, .gd_fetch(tl, b, names(b$jobs)), "source")
  if (isTRUE(garry_opt("progress"))) {
    t <- proc.time()[["elapsed"]] - t0
    cli::cli_inform(.glue(
      "[gdal-direct] per-task sums: ",
      "warp={formatC(sum(vapply(r, function(x) x$tw, 0)), format = 'f', digits = 1)}s"
    ))
    cli::cli_inform(.glue(
      "[gdal-direct] fetch+warp={formatC(t, format = 'f', digits = 2)}s"
    ))
  }
  b$jobs
}

# Build the per-source warp job bundle WITHOUT dispatching: `jobs` (keyed by
# source node id, each with its .bin path) and the grid-constant bundle `K`
# sent once via mirai .args. Callers warp all sources at once
# (.gd_warp_sources) or per-asset (the fetch-ordered pipeline).
.gd_build_jobs <- function(plan, grid, tmp) {
  graph <- plan@graph
  srcs <- Filter(function(s) s@kind == "source_read", plan@stages)
  jobs <- lapply(srcs, function(s) {
    n <- graph_get(graph, s@members[[1L]])
    e <- .gti_meta(n@path)$entries
    sl <- .gti_slice_of(n@open_options) # eligibility made it NA or a label
    er <- if (is.na(sl)) e else e[e$slice == sl, , drop = FALSE]
    list(
      locs = .mpc_resign(er$location),
      dt = er$datetime,
      band = as.integer(n@band),
      nodata = n@nodata,
      resampling = n@resampling,
      bin = file.path(tmp, .glue("n{n@id}.bin"))
    )
  })
  names(jobs) <- vapply(srcs, function(s) as.character(s@members[[1L]]), "")
  K <- list(
    nx = grid@dims[["x"]],
    ny = grid@dims[["y"]],
    gtstr = paste(.gdal_num(grid@transform), collapse = "/"),
    wkt = gdalraster::srs_to_wkt(grid@crs)
  )
  list(K = K, jobs = jobs)
}

# Preload garry once per daemon (else fetch tasks cold-init XLA) and
# start the run. The GDAL config is garry_daemons()'s, for the pool's life.
.gd_daemon_prep <- function(prof) {
  .garry_abi_check(prof)
  .daemons_run_start(prof)
}

# Launch the warp-on-read of sources `ids` WITHOUT blocking (b from
# .gd_build_jobs()), handles named by task key. Raw mirai() per job with
# the task fn resolved BY NAME on the daemon, the same pattern as the
# scheduler's launch functions. mirai_map() ships the function object
# inside every task's .args; measured on this pipeline that per-task
# overhead inflates from ~6 ms (idle pool) to ~100 ms once the read
# daemons are busy with live warps, serialising a 220-task dispatch into
# ~25 s of host stall that delayed every downstream phase (the "slow
# lead-in").
.gd_fetch <- function(tl, b, ids) {
  stats::setNames(
    lapply(ids, function(id) {
      .task_launch(
        tl,
        paste0("f", id, "_c1"),
        quote(asNamespace("garry")$.cd_fetch_warp(j, k)),
        j = b$jobs[[as.character(id)]],
        k = b$K,
        .compute = "garry_read",
        .pool = "read",
        .mb = 4 * as.numeric(b$K$nx) * b$K$ny / 2^20
      )
    }),
    paste0("f", ids, "_c1")
  )
}

# Wait for a fetch group, logging each landing. Returns what each task
# returned.
.gd_fetch_land <- function(tl, handles, label) {
  r <- Map(
    function(h, key) {
      .task_landed(tl$line, key, .await_task(h, "garry_read", lost = "return"))
    },
    handles,
    names(handles)
  )
  tl$tick()
  .gd_check_fetch(r, label)
}

# A read is the run's failure: a collected fetch group aborts on a failed
# warp, or a reader lost under one, naming the source and the cause.
.gd_check_fetch <- function(r, label) {
  errs <- Filter(function(x) inherits(x, "errorValue"), r)
  if (length(errs)) {
    .task_abort(
      .glue("gdal-direct: {length(errs)}/{length(r)} {label} warps failed"),
      errs[[1L]],
      "garry_read_error"
    )
  }
  invisible(r)
}

# The task log of a gdal-direct run: one per route call, however many
# composites it holds.
.gd_log_open <- function() {
  .task_log_open(.garry_run_id(), c(read = .gd_n_compute("garry_read"), comp = .comp_n()))
}

# tmpfs dir for a run's per-source .bin payloads.
# A fresh scratch dir per run: tasks orphaned by an aborted run (the pools
# have no dispatcher to cancel them) must not write into the next run's
# files, which reuse node-id names.
.gd_tmp <- function() {
  tmp <- tempfile(
    .glue("gdirect-{Sys.getpid()}-"),
    tmpdir = if (dir.exists("/dev/shm")) "/dev/shm" else tempdir()
  )
  dir.create(tmp)
  tmp
}

# Say if a warm-up failed. The bands all succeeded by now, so the kernels
# compiled in their tasks instead, at a cost only in time. A warm-up runs
# ahead of its daemon's strips, so this looks without waiting.
.gd_warm_report <- function(warm, tl) {
  done <- Filter(Negate(mirai::unresolved), warm)
  for (key in names(done)) {
    .task_landed(tl$line, key, done[[key]]$data)
  }
  failed <- Filter(function(h) inherits(h$data, "miraiError"), done)
  if (length(failed)) {
    why <- .task_failure(failed[[1L]]$data)
    cli::cli_warn(
      c("a kernel warm-up failed on {length(failed)} daemon{?s}; band tasks compiled it instead.", "x" = "{why}"),
      class = c("garry_warmup_warning", "garry_warning")
    )
  }
  invisible(NULL)
}

# Materialise the per-band results and write the composite GTiff (or return the
# matrices when path is NULL). Shared by the direct and pipeline paths.
.gd_write_result <- function(
  res,
  spec,
  path,
  nodata,
  band_names = NULL,
  wspec = NULL
) {
  mats <- lapply(res, .sv_materialise) # one per band
  if (is.null(path)) {
    return(if (spec$n_bands == 1L) mats[[1L]] else mats)
  }
  nd <- as.numeric(nodata)
  ds <- .sink_output(path, spec$grid, nd, band_names, wspec[c("dtype", "options")])
  on.exit(try(ds$close(), silent = TRUE), add = TRUE)
  for (b in seq_along(mats)) {
    gdal_write_window(
      ds,
      0L,
      0L,
      mats[[b]],
      wspec$dtype %||% spec$grid@dtype,
      nodata = nd,
      band = b
    )
  }
  gdal_close_output(ds, path)
}

# A mask chain as it crosses a process or outlives a run.
.gd_slim_chain <- function(chain) {
  lapply(chain, function(n) {
    n@fn <- .slim_fn(n@fn)
    n
  })
}

# Everything the whole-grid kernel of a composite closes over.
.gd_cube_key <- function(spec) {
  rlang::hash(list(
    fn = .cd_fn_sig(spec$F),
    chain = .cd_chain_sig(spec$mask_chain),
    halo = spec$halo,
    op = spec$op,
    nan_rm = spec$nan_rm,
    affine = spec$band_affine,
    masked = length(spec$fmask_srcs) > 0L,
    dims = spec$grid@dims[c("y", "x")],
    dev = spec$device
  ))
}

# The whole-grid kernel of a single-band composite: the mask replayed
# over the fmask cube and the band reduced under it. A factory for
# .gd_mask_fn()'s reason.
.gd_cube_fn <- function(spec) {
  F <- .slim_fn(spec$F)
  chain <- .gd_slim_chain(spec$mask_chain)
  halo <- spec$halo
  op <- spec$op
  nan_rm <- spec$nan_rm
  aff <- spec$band_affine[[1L]]
  masked <- length(spec$fmask_srcs) > 0L
  rm(spec)
  function(inp) {
    x <- inp[[1L]]
    if (length(aff$scale) == 1L) {
      x <- x * aff$scale + aff$offset
    }
    m <- if (masked) F(x, .gd_replay_mask(inp[[2L]], chain, halo)) else x
    list(.apply_reduce(op, m, 1L, nan_rm))
  }
}

#' Execute a masked composite (its mask cleanup focals replayed) via the
#' lean GDAL-direct cube path.
#' @noRd
.execute_composite_direct <- function(
  plan,
  spec,
  path = NULL,
  nodata = NULL,
  band_names = NULL,
  wspec = NULL
) {
  tmp <- .gd_tmp()
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  tl <- .gd_log_open()
  on.exit(tl$line("host_end", "-"), add = TRUE)
  # Multi-band takes the split-pool pipeline: it overlaps the mask and
  # per-band medians with the band fetch on the read pool, so only the
  # last band's median is exposed after the drain (distributed execution
  # requires garry_daemons(), so the pools are guaranteed here). A single
  # band is fetch-bound, and its whole-grid kernel runs once the fetch has
  # drained.
  if (spec$n_bands > 1L) {
    res <- .gd_reduce_results(plan, spec, tmp, tl)
    tl$line("drain_end", "-")
    return(.gd_write_result(res, spec, path, nodata, band_names, wspec = wspec))
  }

  nx <- spec$grid@dims[["x"]]
  ny <- spec$grid@dims[["y"]]
  jobs <- .gd_warp_sources(plan, spec$grid, tmp, tl)
  tl$line("drain_end", "-")
  masked <- length(spec$fmask_srcs) > 0L
  # COMPUTE: one lean whole-grid kernel in this process. The apply_mask
  # (incl. morphology focals) is replayed on the whole fmask cube,
  # vectorised over time.
  tcomp <- system.time({
    dev <- .exec_device(spec$device)
    cube <- function(ids) {
      g_upload_raw(
        do.call(
          c,
          lapply(ids, function(id) {
            readBin(jobs[[as.character(id)]]$bin, "raw", n = as.numeric(ny) * nx * 4)
          })
        ),
        "f32",
        c(length(ids), ny, nx),
        device = dev
      )
    }
    inputs <- list(cube(spec$band_srcs[[1L]]))
    if (masked) {
      inputs[[2L]] <- cube(spec$fmask_srcs)
    }
    jf <- .host_kernel(.gd_cube_key(spec), .gd_cube_fn(spec), dev)
    res <- g_download(jf(inputs))
  })[["elapsed"]]
  if (isTRUE(garry_opt("progress"))) {
    cli::cli_inform(.glue(
      "[gdal-direct] lean compute={formatC(tcomp, format = 'f', digits = 2)}s"
    ))
  }
  .gd_write_result(res, spec, path, nodata, band_names, wspec = wspec)
}

# The fetch-ordered per-band compute of the composite pipeline: fetch fmask
# first on the read pool, compute the cleaned mask on the compute pool while
# the bands download, then dispatch each band's reduce as its fetch lands
# (overlapped, RAM-capped), so band B's runs while later bands still fetch.
# Returns the list of per-band raw f32 payloads (band-source order); the
# caller writes or feeds them to an upper kernel. `tmp` and the task log `tl` are caller-owned (shared
# across groups).
.gd_reduce_results <- function(plan, spec, tmp, tl) {
  ny <- spec$grid@dims[["y"]]
  nx <- spec$grid@dims[["x"]]
  progress <- isTRUE(garry_opt("progress"))
  masked <- length(spec$fmask_srcs) > 0L
  # Compute dispatch rides the width-1 profile set: warm every profile,
  # round-robin the mask/band jobs across them.
  comp_profs <- .comp_profiles()
  cp_i <- 0L
  next_cp <- function() {
    cp_i <<- cp_i + 1L
    comp_profs[[1L + (cp_i - 1L) %% length(comp_profs)]]
  }

  b <- .gd_build_jobs(plan, spec$grid, tmp)
  bin_of <- function(ids) {
    vapply(ids, function(id) b$jobs[[as.character(id)]]$bin, "")
  }

  t0 <- proc.time()[["elapsed"]]
  .gd_daemon_prep("garry_read")
  # Dispatch fmask FIRST (it drains before the bands, which queue behind it on
  # the read pool), then the bands. All non-blocking.
  fmask_p <- if (masked) .gd_fetch(tl, b, spec$fmask_srcs) else NULL
  band_p <- lapply(spec$band_srcs, function(ids) .gd_fetch(tl, b, ids))
  # Kernel identity for the lean band kernel: everything the traced
  # closure closes over (F, op, nan_rm, affine, masked, device). Affine
  # varies per band, so bands sharing an affine share a ck, and with it
  # one kernel per daemon (see .daemon_kernel).
  Fs <- .slim_fn(spec$F)
  base_sig <- rlang::hash(list(
    fn = .cd_fn_sig(spec$F),
    op = spec$op,
    nan_rm = spec$nan_rm,
    masked = masked,
    dev = spec$device
  ))
  band_ck <- vapply(
    seq_along(spec$band_srcs),
    function(bi) {
      rlang::hash(list(base_sig, spec$band_affine[[bi]]))
    },
    ""
  )

  # Strip grid: spread each band's median across the pool so the exposed
  # drain (the bands with no fetch left to hide behind) divides by the
  # pool width instead of landing whole on one daemon.
  ns_opt <- as.integer(garry_opt("gd_strips"))
  bounds <- .gd_strip_bounds(
    ny,
    if (ns_opt >= 1L) ns_opt else max(1L, .comp_n())
  )
  ns <- length(bounds)

  # Warm + attach the compute pool while the read pool fetches: hide the
  # XLA client cold init AND the lean kernels' compiles (one per distinct
  # ck, executed per strip height on zero-byte g_fill dummies) inside the
  # fetch window, so no post-drain strip pays a compile.
  hs <- unique(vapply(bounds, `[[`, integer(1), 2L))
  wsp <- unname(lapply(which(!duplicated(band_ck)), function(bi) {
    list(
      ck = band_ck[[bi]],
      F = Fs,
      op = spec$op,
      nan_rm = spec$nan_rm,
      affine = spec$band_affine[[bi]],
      masked = masked,
      dev = spec$device,
      n = length(spec$band_srcs[[bi]]),
      hs = hs,
      nx = nx
    )
  }))
  warm <- stats::setNames(
    lapply(seq_along(comp_profs), function(i) {
      .task_launch(
        tl,
        paste0("warm0_c", i),
        quote({
          suppressMessages(library(garry))
          asNamespace("garry")$.gd_warm_pipeline(sp)
        }),
        sp = wsp,
        .compute = comp_profs[[i]],
        .pool = "comp",
        .slot = comp_profs[[i]]
      )
    }),
    paste0("warm0_c", seq_along(comp_profs))
  )

  # Mask: once fmask lands, compute the cleaned cube on the compute pool while
  # the bands are still fetching. One mask .bin, read by every band median.
  mask_bin <- tempfile("mask", tmpdir = tmp, fileext = ".bin")
  mask_p <- NULL
  if (masked) {
    fmr <- .gd_fetch_land(tl, fmask_p, "fmask")
    if (progress) {
      cli::cli_inform(.glue(
        "[gdal-direct] fmask ",
        "drain={formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s ",
        "({length(fmr)} tasks, warp ",
        "sum={formatC(sum(vapply(fmr, function(r) r$tw, 0)), format = 'f', digits = 1)}s)"
      ))
    }
    Km <- list(
      fmask_bins = bin_of(spec$fmask_srcs),
      out_bin = mask_bin,
      chain = .gd_slim_chain(spec$mask_chain),
      halo = spec$halo,
      ny = ny,
      nx = nx,
      dev = spec$device,
      ck = rlang::hash(list(
        chain = .cd_chain_sig(spec$mask_chain),
        halo = spec$halo,
        ny = ny,
        nx = nx,
        dev = spec$device
      ))
    )
    mask_key <- paste0("m", spec$fmask_srcs[[1L]], "_c1")
    p <- next_cp()
    mask_p <- .task_launch(
      tl,
      mask_key,
      quote(asNamespace("garry")$.gd_compute_mask(km)),
      km = Km,
      .compute = p,
      .pool = "comp",
      .slot = p,
      .mb = 8 * length(spec$fmask_srcs) * as.numeric(ny) * nx / 2^20
    )
  }

  # Per-band medians, strip-decomposed: wait each band's fetch, then dispatch
  # its strips (async, round-robin across the profiles) so they overlap the
  # remaining bands' fetches -- but never let more than `cap` strip tasks be
  # in flight, so the executing working sets stay under the RAM budget (a
  # generous / many-band pool then drains in memory-bounded waves, not a
  # spike). Strips reassemble by raw concatenation in y order: the payloads
  # are row-major f32, so the result is byte-identical to a whole-band job.
  Kb <- list(
    F = Fs,
    op = spec$op,
    nan_rm = spec$nan_rm,
    ny = ny,
    nx = nx,
    dev = spec$device,
    mask_bin = if (masked) mask_bin else character(0)
  )
  n_slices <- length(spec$band_srcs[[1L]])
  strip_h <- bounds[[1L]][[2L]]
  cap <- .gd_compute_cap(n_slices, strip_h, nx, .daemon_depth * max(1L, .comp_n()))
  nb <- length(spec$band_srcs)
  if (progress && cap < nb * ns) {
    cli::cli_inform(.glue(
      "[gdal-direct] compute in-flight capped at {cap} strip task(s) (RAM budget)"
    ))
  }
  mask_done <- !masked
  parts <- lapply(seq_len(nb), function(i) vector("list", ns))
  got <- integer(nb)
  res <- vector("list", nb)
  t_comp <- 0
  jit_creates <- 0L
  inflight <- list() # dispatched, not yet collected (FIFO)
  harvest <- function() {
    it <- inflight[[1L]]
    inflight <<- inflight[-1L]
    v <- .await_task(it$h, comp_profs)
    if (inherits(v, "miraiError")) {
      .task_abort(.glue("gdal-direct pipeline compute failed on band {it$bi} strip {it$si}"), v)
    }
    v <- .task_landed(tl$line, it$key, v)
    tl$tick()
    t_comp <<- t_comp + (attr(v, "gd_t") %||% 0)
    jit_creates <<- jit_creates + (attr(v, "gd_jit") %||% 0L)
    attr(v, "gd_t") <- NULL
    attr(v, "gd_jit") <- NULL
    parts[[it$bi]][[it$si]] <<- v
    got[[it$bi]] <<- got[[it$bi]] + 1L
    if (got[[it$bi]] == ns) {
      res[[it$bi]] <<- if (ns == 1L) {
        parts[[it$bi]][[1L]]
      } else {
        p <- do.call(
          c,
          lapply(parts[[it$bi]], function(x) {
            attributes(x) <- NULL
            x
          })
        )
        attr(p, "gdim") <- c(ny, nx)
        attr(p, "gdt") <- "f32"
        p
      }
      parts[[it$bi]] <<- list()
    }
  }
  for (bi in seq_len(nb)) {
    .gd_fetch_land(tl, band_p[[bi]], .glue("band {bi}"))
    if (progress) {
      cli::cli_inform(.glue(
        "[gdal-direct] band {bi} drained at ",
        "{formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s"
      ))
    }
    if (!mask_done) {
      mv <- .await_task(mask_p, comp_profs) # the mask .bin must exist first
      if (inherits(mv, "miraiError")) {
        .task_abort("gdal-direct mask computation failed", mv)
      }
      .task_landed(tl$line, mask_key, mv)
      tl$tick()
      mask_done <- TRUE
    }
    for (si in seq_len(ns)) {
      while (length(inflight) >= cap) {
        harvest()
      } # RAM cap: bound concurrency
      jb <- list(
        band_bins = bin_of(spec$band_srcs[[bi]]),
        affine = spec$band_affine[[bi]],
        rows = if (ns == 1L) NULL else bounds[[si]],
        ck = band_ck[[bi]]
      )
      key <- paste0("b", spec$band_srcs[[bi]][[1L]], "_c", si)
      p <- next_cp()
      h <- .task_launch(
        tl,
        key,
        quote(asNamespace("garry")$.gd_compute_masked_band(jb, kb)),
        jb = jb,
        kb = Kb,
        .compute = p,
        .pool = "comp",
        .slot = p,
        .mb = .gd_strip_mb(n_slices, strip_h, nx)
      )
      inflight[[length(inflight) + 1L]] <- list(bi = bi, si = si, key = key, h = h)
    }
  }
  if (progress) {
    cli::cli_inform(.glue(
      "[gdal-direct] fetch+dispatch=",
      "{formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s"
    ))
  }
  while (length(inflight)) {
    harvest()
  }
  .gd_warm_report(warm, tl)
  if (progress) {
    cli::cli_inform(.glue(
      "[gdal-direct] pipeline ",
      "total={formatC(proc.time()[['elapsed']] - t0, format = 'f', digits = 2)}s ",
      "(compute sum={formatC(t_comp, format = 'f', digits = 2)}s, ",
      "{ns} strip/band, {jit_creates} post-warm compile)"
    ))
  }
  res
}

#' Recognise any warp-on-read-replayable plan and lift its whole IR, or NULL.
#' @noRd
.gd_spec <- function(plan) {
  src_stages <- .gd_source_stages(plan)
  if (is.null(src_stages)) {
    return(NULL)
  }
  graph <- plan@graph
  sink <- plan@stages[[plan@sink]]
  sink_out <- sink@members[[length(sink@members)]]
  ids <- .reachable(graph, sink_out) # ascending = topo
  nds <- lapply(ids, function(id) graph_get(graph, id))
  ok_type <- function(n) {
    S7::S7_inherits(n, SourceNode) ||
      S7::S7_inherits(n, MapNode) ||
      S7::S7_inherits(n, FocalNode) ||
      S7::S7_inherits(n, StackNode) ||
      S7::S7_inherits(n, ReduceNode)
  }
  if (!all(vapply(nds, ok_type, logical(1)))) {
    return(NULL)
  } # Warp -> sched
  is_src <- vapply(nds, function(n) S7::S7_inherits(n, SourceNode), logical(1))
  input_nodes <- ids[is_src]
  src_ids <- vapply(
    src_stages,
    function(s) {
      graph_get(graph, s@members[[1L]])@id
    },
    integer(1)
  )
  if (!all(input_nodes %in% src_ids)) {
    return(NULL)
  }
  members <- ids[!is_src]
  list(
    members = members,
    input_nodes = input_nodes,
    sink_out = sink_out,
    halo = .stage_halo(graph, members, input_nodes),
    grid = sink@grid,
    device = sink@device
  )
}

# The kernel of a gdal-direct route's upper IR, on the host. Its one
# export comes back by position: a cached kernel's names are those of the
# plan that compiled it.
.gd_host_kernel <- function(graph, g, dev) {
  .host_kernel(
    paste0(
      .kernel_sig(graph, g$input_nodes, g$members, g$sink_out, halo = g$halo),
      "@",
      g$device
    ),
    .compose_stage_fn(graph, g$members, g$input_nodes, list(g$sink_out), g$halo),
    dev
  )
}

# Write or return a whole-grid kernel's one result, band by band.
.gd_write_stack <- function(res, grid, path, nodata, band_names, wspec) {
  m <- .sv_materialise(res)
  mats <- if (length(dim(m)) == 3L) {
    lapply(seq_len(dim(m)[[1L]]), function(b) m[b, , ])
  } else {
    list(m)
  }
  spec <- list(n_bands = length(mats), grid = grid)
  .gd_write_result(mats, spec, path, nodata, band_names, wspec = wspec)
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
# Byte-identical to one whole-grid kernel: each leaf reduce yields
# the same 2D result whether computed whole-grid or via the pipeline, and the
# upper kernel is the same nodes .compose_stage_fn would run whole-grid. The
# only round-trip is materialising each leaf reduce to an f32 matrix and
# re-uploading it (f32 -> double -> f32 is exact), so the upper maths is bit-
# identical.
# ---------------------------------------------------------------------------

#' Recognise a reduce-decomposable plan and lift its groups + upper IR, or NULL.
#'
#' NULL when there is no upper IR (a pure composite -> `.cd_spec`), when a leaf
#' reduce is not composite-reducible, or when the upper IR does not close over
#' the leaf reduces (a node consuming a raw source alongside a reduce -> the
#' scheduler). `.gd_spec` gates fetchability and the node-type whitelist.
#' @noRd
.gd_decompose <- function(plan) {
  gsp <- .gd_spec(plan) # fetchable GTI + Source/Map/Focal/Stack/Reduce
  if (is.null(gsp)) {
    return(NULL)
  }
  graph <- plan@graph
  gg <- function(id) graph_get(graph, id)
  sink_out <- gsp$sink_out
  ids <- .reachable(graph, sink_out)
  is_red_t <- function(n) S7::S7_inherits(n, ReduceNode) && "t" %in% n@over
  # Leaf temporal reduces: a reduce over t with no reduce anywhere below it.
  leaf_ids <- Filter(
    function(id) {
      if (!is_red_t(gg(id))) {
        return(FALSE)
      }
      below <- setdiff(.reachable(graph, id), id)
      !any(vapply(below, function(s) is_red_t(gg(s)), logical(1)))
    },
    ids
  )
  if (!length(leaf_ids)) {
    return(NULL)
  }
  specs <- lapply(leaf_ids, function(id) .cd_reduce_spec(gg, gg(id)))
  if (any(vapply(specs, is.null, logical(1)))) {
    return(NULL)
  }

  # Upper IR: nodes strictly above the leaf reduces (their subtrees are the
  # inputs). No upper members -> pure composite, not our job.
  subtrees <- unique(unlist(lapply(leaf_ids, function(id) {
    .reachable(graph, id)
  })))
  members <- setdiff(ids, subtrees) # ascending == topo
  if (!length(members)) {
    return(NULL)
  }
  # Every upper member's parents must resolve to an upper member or a leaf
  # reduce (else a raw non-reduced source feeds the upper IR -> scheduler).
  leaf_set <- unlist(leaf_ids)
  ok <- all(vapply(
    members,
    function(id) {
      all(gg(id)@parents %in% c(members, leaf_set))
    },
    logical(1)
  ))
  if (!ok) {
    return(NULL)
  }

  # Group leaf reduces that form ONE composite (shared mask/op) -> one pipeline
  # call computes them as a multi-band composite with fetch overlap.
  gkey <- vapply(specs, .cd_group_key, "")
  groups <- lapply(unique(gkey), function(k) {
    idx <- which(gkey == k)
    list(
      reduce_ids = unlist(leaf_ids[idx]),
      spec = .cd_group_spec(specs[idx], gsp$grid, gsp$device)
    )
  })
  list(
    groups = groups,
    upper = list(
      members = members,
      input_nodes = leaf_set,
      sink_out = sink_out,
      halo = .stage_halo(graph, members, leaf_set),
      grid = gsp$grid,
      device = gsp$device
    )
  )
}

#' Execute a reduce-decomposable plan: overlap-compute the leaf reduces, then
#' run the upper IR on the materialised results.
#' @noRd
.execute_gd_reduce <- function(
  plan,
  decomp,
  path = NULL,
  nodata = NULL,
  band_names = NULL,
  wspec = NULL
) {
  graph <- plan@graph
  tmp <- .gd_tmp()
  on.exit(unlink(tmp, recursive = TRUE), add = TRUE)
  tl <- .gd_log_open()
  on.exit(tl$line("host_end", "-"), add = TRUE)
  u <- decomp$upper
  dev <- .exec_device(u$device)
  h <- u$halo

  # 1. Each group's leaf reduces via the overlapped per-band pipeline, keyed by
  #    reduce node id (band-source order == reduce_ids order).
  leaf <- new.env(parent = emptyenv())
  for (grp in decomp$groups) {
    res <- .gd_reduce_results(plan, grp$spec, tmp, tl)
    mats <- lapply(res, .sv_materialise)
    for (i in seq_along(grp$reduce_ids)) {
      leaf[[.key(grp$reduce_ids[[i]])]] <- mats[[i]]
    }
  }
  tl$line("drain_end", "-")

  # 2. Upper IR on the materialised 2D leaf results, one lean kernel.
  tcomp <- system.time({
    inputs <- lapply(u$input_nodes, function(id) {
      a <- g_upload(leaf[[.key(id)]], "f32", device = dev)
      if (h > 0L) g_pad(a, h, NaN) else a
    })
    res <- g_download(.gd_host_kernel(graph, u, dev)(inputs))[[1L]]
  })[["elapsed"]]
  if (isTRUE(garry_opt("progress"))) {
    cli::cli_inform(.glue(
      "[gdal-direct] upper compute={formatC(tcomp, format = 'f', digits = 2)}s"
    ))
  }
  .gd_write_stack(res, u$grid, path, nodata, band_names, wspec)
}
