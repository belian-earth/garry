#' @include pools.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Distributed executor over mirai daemons (Phase 7, decision D16).
#
# Tasks are keyed (stage_id, chunk_idx). Dependencies: source/warp chunk
# tasks are free; compute/reduce_partial chunk j depends on chunk j of
# each input stage (chunk tables are aligned in v1); reduce_combine and
# final assembly run on the host once their inputs land.
#
# Inter-stage store: mori POSIX shared memory — daemons pin the regions
# they create for a run and the host refcounts them per consuming task
# (see `garry.store` below). No mid-graph halo store is needed (D11):
# halos ride inside source/warp regions.
#
# Scheduler: polling ready-queue over N width-1 compute profiles
# (daemon-identity routing, design/routed-dispatch.md) with byte-budget
# admission as back-pressure. Daemons jit stage closures on first use
# and keep them in a per-process cache; per-profile warmth makes
# key-only launches exact (D14).
# ---------------------------------------------------------------------------

# Structural kernel signature: content-addressed jit cache key. Two
# stages with the same signature trace to the same XLA program for
# the same input shapes, so daemons compile ONE kernel for e.g. 55
# per-slice mask-cleanup stages instead of 55 (measured: the
# morphology benchmark's compile storm) — and identical kernels
# persist across runs. Node ids are normalized to stage-local
# indices (inputs in stored order, then members ascending); member
# fns compare by their serialized slimmed closures, so captured free
# variables participate in the identity. The only per-stage residue
# is export NAMES (node ids baked into the composed closure), which
# the task bodies overwrite positionally via `out_keys` — exports
# are sorted ascending in every composed fn, so position is
# meaning.
.stage_kernel_sig <- function(graph, s) {
  ids <- c(s@input_nodes, s@members)
  local <- stats::setNames(seq_along(ids), as.character(ids))
  norm_fn <- function(f) serialize(.slim_fn(f), NULL)
  parts <- lapply(s@members, function(id) {
    n <- graph_get(graph, id)
    base <- list(
      cls = class(n)[[1L]],
      parents = unname(local[as.character(n@parents)]),
      dtype = n@grid@dtype,
      pdims = names(graph_get(graph, n@parents[[1L]])@grid@dims))
    if (S7::S7_inherits(n, MapNode)) base$fn <- norm_fn(n@fn)
    if (S7::S7_inherits(n, FocalNode)) {
      base$fn <- norm_fn(n@fn)
      base$radius <- n@radius
      base$boundary <- n@boundary
      base$weights <- n@weights
    }
    if (S7::S7_inherits(n, ReduceNode)) {
      base$op <- n@op
      base$over <- n@over
      base$nan_rm <- n@nan_rm
      # A custom reducer's identity lives in its fn, not `op`; omitting
      # it would alias distinct kernels in the jit cache.
      if (length(n@fn)) base$fn <- norm_fn(n@fn[[1L]])
    }
    if (S7::S7_inherits(n, ScanNode)) {
      base$over <- n@over
      base$direction <- n@direction
      base$out_dtype <- n@dtype
      base$fn <- norm_fn(n@fn[[1L]])
    }
    if (S7::S7_inherits(n, PatchNode)) {
      # A patch kernel's identity is its content hash, NEVER a
      # serialization of fn: a model closure carries tens of MB of
      # weights, and per-slice stages sharing one model must collapse
      # to one kernel signature (one warm-up, one XLA compile).
      base$radius <- n@radius
      base$out_bands <- n@out_bands
      base$out_dtype <- n@dtype
      base$kernel_id <- n@kernel_id
    }
    base
  })
  sig <- list(kind = s@kind, halo = s@halo, out_pad = s@out_pad,
              parts = parts,
              n_inputs = length(s@input_nodes),
              exports = unname(local[as.character(s@exports)]))
  # In-memory hash: the previous tempfile + tools::md5sum round-trip
  # cost a file write/read/unlink per call, and the fuse-eligibility
  # loop calls this once per single-input compute stage.
  paste0("k", rlang::hash(sig))
}


# Store-resident bytes (MB) one region pins: core window clipped to the
# grid, padded by `pad` per side, times the outer-dim plane count, at
# the region's true element size. Shared by read windows (pad = halo),
# fused outputs (pad = out_pad, nb = the EXPORT's planes -- pricing a
# fused region from its source window over-charged a fused multi-band
# read by the band count and would serialise the fleet) and compute
# outputs. `bytes` comes from .store_bytes_of: 4 only for raw f32; f64
# is 8 whether raw or doubles (the old use_raw flag booked f64 regions
# at half their size).
.store_region_mb <- function(chunk_dim, grid_dims, pad, nb, bytes) {
  prod(pmin(as.numeric(chunk_dim),
            as.numeric(grid_dims[c("x", "y")])) + 2 * pad) *
    max(1, nb) * bytes / 2^20
}

# Element bytes a stored region of `dtype` costs under the run's store
# mode: the raw store keeps f32 at 4 B; everything else (f64 raw or
# any doubles fallback) is 8 B.
.store_bytes_of <- function(dtype, use_raw) {
  if (use_raw && identical(dtype, "f32")) 4 else 8
}

# Outer-dim plane count of a node's grid (bands, time slices).
.node_outer_nb <- function(graph, nid) {
  d <- graph_get(graph, nid)@grid@dims
  max(1, prod(as.numeric(d[!names(d) %in% c("x", "y")])))
}

#' Execute a Plan across mirai daemons.
#'
#' Requires garry's daemon pools: call [garry_daemons()] first (the
#' function errors when the pools are not running). Results are
#' identical to [execute_plan()] (same plan, same kernels).
#'
#' @param plan A `Plan`.
#' @param path,nodata,band_names,wspec As in [execute_plan()].
#' @return As [execute_plan()].
#' @seealso [collect()], [garry_daemons()]
#' @export
execute_plan_mirai <- function(plan, path = NULL, nodata = NULL, band_names = NULL,
                               wspec = NULL) {
  .garry_opt_check()
  # Distributed execution runs on the garry_daemons() split pools: read/warp
  # tasks route to the read pool — where anvl/PJRT never loads, so a reader
  # stays at ~60 MB — and compute tasks to a small pool of fat daemons,
  # confining per-chunk working sets to few processes.
  if (!garry_daemons_set())
    .garry_error(paste0(
      "no garry daemon pools are running; call garry_daemons() first"),
      "garry_scheduler_error")
  n_read <- .gd_n_compute("garry_read")
  n_comp <- .comp_n()
  read_prof <- "garry_read"
  comp_profs <- .comp_profiles()
  profiles <- unique(c(read_prof, comp_profs))
  # Per-profile launch slots (width-1 profiles, depth 2 each) and EXACT
  # per-profile kernel warmth: key-only launches go only to a profile
  # that provably holds the kernel. Scan tasks are CONFINED to
  # `scan_profs` (set once the plan is known), at most one cold compile
  # in flight per profile — the structural bound that replaced the
  # probabilistic slow-start ramp and the scan-compile byte surcharge
  # (both retired 2026-08-02; the surcharge was twice miscalibrated in
  # the field, and workstream B measured anonymous rotation growing
  # EVERY daemon to the scan working set).
  prof_depth <- 2L
  prof_slots <- new.env(parent = emptyenv())
  for (p in comp_profs) prof_slots[[p]] <- 0L
  prof_warm <- new.env(parent = emptyenv())      # "prof\x1fck" -> TRUE
  prof_cold_busy <- new.env(parent = emptyenv()) # prof -> TRUE while compiling
  scan_profs <- character(0)                     # set after plan_has_scan
  .pw_key <- function(p, ck) paste0(p, "\x1f", ck)
  pick_comp_prof <- function(t) {
    is_cold <- !is.null(t$ck) && isTRUE(t$scan)
    cands <- if (is_cold && length(scan_profs)) scan_profs
             else if (length(scan_profs) &&
                      length(comp_profs) > length(scan_profs) && !is_cold)
               # ordinary kernels prefer the non-scan profiles (keeps
               # them lean); scan profiles remain a fallback
               c(setdiff(comp_profs, scan_profs), scan_profs)
             else comp_profs
    if (is_cold) {
      # a warm profile first (exact key-only launch), least-loaded
      best <- NULL; bn <- prof_depth
      for (p in cands) {
        v <- prof_slots[[p]]
        if (v < bn && isTRUE(prof_warm[[.pw_key(p, t$ck)]])) {
          bn <- v; best <- p
        }
      }
      if (!is.null(best)) return(best)
      # else a designated profile not currently compiling
      for (p in cands) {
        if (prof_slots[[p]] < prof_depth &&
            !isTRUE(prof_cold_busy[[p]])) return(p)
      }
      return(NULL)
    }
    best <- NULL; bn <- prof_depth
    for (p in cands) {
      v <- prof_slots[[p]]
      if (v < bn) { bn <- v; best <- p }
    }
    best
  }
  .garry_abi_check(unique(c(profiles,
    if (tryCatch(.gd_n_compute("garry_write") > 0L, error = function(e) FALSE))
      "garry_write")))
  # Back-pressure: reads throttle on slots + resident-store bytes;
  # compute launches are gated by a BYTE budget (below) — per-task
  # resident estimates against the live RAM pool — so many small
  # chunks (per-slice mask cleanup, ~10 MB each) flow at full pool
  # width while big fused medians (~350 MB each) self-limit.
  # compute_inflight remains an optional hard count cap on top.
  cap_read <- max(2L * n_read, 4L)
  cap_comp <- 2L * n_comp                    # comp-pool slot depth
  cap_comp_opt <- garry_opt("compute_inflight")  # optional hard cap
  # In-flight compute is bounded by the RAM pool (refresh_mem_budgets,
  # below) and the cap_comp slot count -- NOT a fixed per-daemon constant.
  # ram_budget_mb is the per-CHUNK size target (the chunking pass, passes.R);
  # using ram_budget_mb x n_comp as the in-flight byte cap starved a single
  # daemon's second (queued) slot -- so the daemon idled between runs -- and
  # at high daemon counts grew the cap past real RAM into OOM. The pool
  # fraction is the true bound.
  comp_budget_mb <- Inf
  read_budget_mb <- garry_opt("read_budget_mb")
  # Largest co-resident read SET (one window per input of the widest
  # compute stage): filled during task build; the effective read budget
  # is floored above it so a wide stage's full input set can always be
  # resident at once — a budget below one set cannot deadlock (the
  # no-read-in-flight escape hatch still trickles), but it serialises
  # every read of the set, which is a crawl, not back-pressure.
  max_set_mb <- 0

  # User stage closures call the g_* vocabulary unqualified; make sure
  # the package is attached on every daemon (idempotent, once per call).
  # Read policy is resolved host-side and shipped: daemons don't
  # inherit host options.
  # Ship read policy + run-start trim to every daemon (the trim gives
  # back what the previous plan's arenas are hoarding — a tail plan
  # otherwise starts with the fleet standing at the predict plan's
  # high-water).
  .pool_broadcast(quote({
    suppressMessages(library(garry))
    options(garry.read_fail = rf, garry.read_retry = rr)
    garry::.daemon_hygiene()
  }), profiles = profiles, rf = garry_opt("read_fail"),
  rr = garry_opt("read_retry"))

  graph <- plan@graph
  run_id <- as.integer(stats::runif(1, 1, 1e8))
  # Raw f32 store payloads (phase 12c, D19-D21). Resolved once here:
  # daemon processes do not inherit host options, so the flag rides in
  # every task payload.
  use_raw <- .exec_use_raw_store()
  # Inter-stage store is POSIX shared memory (mori): daemons pin every
  # region they created for this run and release them once the host is done
  # (regions outlive tasks, not the run); host-side handles die with
  # `chunk_vals`. Both pools pin regions (readers: windows; computers:
  # results).
  on.exit(for (p in profiles)
    try(mirai::everywhere(garry::.daemon_shm_clear(), .compute = p),
        silent = TRUE), add = TRUE)
  chunk_vals <- new.env(parent = emptyenv())   # task key -> shared value

  # ---- fetch/assemble split (phase 12) --------------------------------
  # GTI source stages over remote locations split into per-item-asset
  # window FETCH tasks (plain gdal_translate -srcwin to tmpfs — many
  # tiny blocking reads keep the link saturated where few big warped
  # reads idle at ~25% duty cycle) plus the ordinary read task
  # ASSEMBLING the mosaic from a location-rewritten local index at
  # local speed. Requires the index sidecar gti_index_create() writes
  # and garry's own "slice = '...'" FILTER form; anything else falls
  # back to direct remote reads.
  fetch_mode <- rlang::arg_match0(garry_opt("fetch"), c("auto", "direct", "force"),
                                  arg_nm = "garry.fetch")
  fetch_root <- NULL
  fetch_state <- new.env(parent = emptyenv())  # orig index -> local info
  fetch_n_idx <- 0L
  fetch_made <- new.env(parent = emptyenv())   # fetch task key -> TRUE
  fetch_files_of <- new.env(parent = emptyenv())  # sid -> files to unlink
  fetch_reads_left <- new.env(parent = emptyenv())  # sid -> open read tasks
  on.exit(if (!is.null(fetch_root))
    unlink(fetch_root, recursive = TRUE), add = TRUE)

  prepare_fetch <- function(rpath, roo, rnodata, grid) {
    if (fetch_mode == "direct" || !startsWith(rpath, "GTI:")) return(NULL)
    ipath <- sub("^GTI:", "", rpath)
    st <- fetch_state[[ipath]]
    if (is.null(st)) {
      meta_f <- paste0(ipath, ".meta.rds")
      if (!file.exists(meta_f)) return(NULL)
      meta <- readRDS(meta_f)
      ent <- meta$entries
      if (!all(c("slice", "location") %in% names(ent))) return(NULL)
      do_fetch <- if (fetch_mode == "force") rep(TRUE, nrow(ent))
                  else grepl("^/vsi", ent$location)
      if (!any(do_fetch)) return(NULL)
      if (is.null(fetch_root)) {
        base <- if (dir.exists("/dev/shm")) "/dev/shm" else tempdir()
        fetch_root <<- file.path(base, sprintf("garry-fetch-%d", run_id))
        dir.create(fetch_root)
      }
      fetch_n_idx <<- fetch_n_idx + 1L
      sub <- file.path(fetch_root, sprintf("i%d", fetch_n_idx))
      dir.create(sub)
      dst <- file.path(sub, sprintf("r%04d.tif", seq_len(nrow(ent))))
      lent <- ent
      lent$location <- ifelse(do_fetch, dst, ent$location)
      lpath <- file.path(sub, basename(ipath))
      gti_index_create(lent, lpath, crs = meta$crs,
                       layer = meta$layer %||% "index")
      st <- list(id = fetch_n_idx, local = paste0("GTI:", lpath),
                 src = ent$location, dst = dst, do = do_fetch,
                 slice = ent$slice)
      fetch_state[[ipath]] <- st
    }
    fl <- grep("^FILTER=", roo, value = TRUE)
    if (length(fl) != 1L) return(NULL)
    slval <- regmatches(fl, regexec("^FILTER=slice = '(.*)'$", fl))[[1]][[2]]
    if (is.na(slval)) return(NULL)
    rows <- which(st$slice == slval & st$do)
    keys <- sprintf("f%d_%d", st$id, rows)
    for (k in seq_along(rows)) {
      key <- keys[[k]]
      if (!is.null(fetch_made[[key]])) next
      fetch_made[[key]] <- TRUE
      local({
        src <- st$src[[rows[[k]]]]; dst <- st$dst[[rows[[k]]]]
        ex <- grid@extent; cr <- grid@crs; nd <- rnodata
        tr <- grid@transform[[2L]]      # target x resolution: decimate coarse fetches
        add_task(key, character(0), "read", prio = 1L,
                 launch = function(prof) {
          mirai::mirai(
            garry::.daemon_fetch_window(src, dst, ex, cr, nodata = nd,
                                        target_res = tr),
            # dispatch-time hook: a fetch launched deep into a long
            # drain re-signs a near-expiry MPC token (io R4)
            src = .mpc_resign(src), dst = dst, ex = ex, cr = cr, nd = nd,
            tr = tr, .compute = prof)
        })
      })
    }
    list(deps = keys, local = st$local,
         files = st$dst[rows])
  }


  # Consumer index in ONE pass over the stage list. Per-stage Filter
  # scans are O(stages^2) in S7 accessor calls — tens of seconds at
  # the ~2000-stage scale of a many-band multi-export plan.
  stage_kind <- vapply(plan@stages, function(s) s@kind, character(1))
  consumers_of <- vector("list", length(plan@stages))
  for (t2 in plan@stages)
    for (i in t2@inputs)
      consumers_of[[i]] <- c(consumers_of[[i]], t2@id)
  # Node id -> producing stage id (first-wins, matching .exec_in_meta's
  # Find over creation order: a spatially-reduced root is a member of
  # both its partial and combine stages, and the PARTIAL produces it).
  node_stage <- integer(length(plan@graph@nodes))
  for (t2 in rev(plan@stages)) node_stage[t2@members] <- t2@id
  warp_only <- vapply(plan@stages, function(s) {
    cons <- consumers_of[[s@id]]
    s@kind == "source_read" && length(cons) > 0L &&
      all(stage_kind[cons] == "warp") &&
      plan@sink != s@id &&
      # A source that is itself a requested sink still needs reading
      # even when its only consumers are warps (matches execute_plan's
      # guard; without it multi-export sink retrieval finds no chunks).
      !any(plan@sinks %in% s@members)
  }, logical(1))

  # Build the task table. Combine stages are host-side, handled at
  # drain. The table is an ENVIRONMENT: named-list `[[<-` inserts do a
  # linear name match plus spine copy each call — O(n^2) over the
  # build, minutes of host time at ~2e4 tasks before anything runs.
  # `seq` records insertion order (ls() on an env is alphabetical),
  # which the launch order below uses as its tie-break.
  tasks <- new.env(parent = emptyenv())
  n_task <- 0L
  add_task <- function(key, deps, pool, launch, mb = 0, prio = 2L,
                       dev = "cpu", store_mb = 0, ck = NULL,
                       scan = FALSE) {
    n_task <<- n_task + 1L
    tasks[[key]] <- list(deps = deps, pool = pool, launch = launch,
                         mb = mb, prio = prio, dev = dev,
                         store_mb = store_mb, seq = n_task, ck = ck,
                         scan = scan,
                         state = "pending")
  }
  # For coarse-reading (split) source stages: task key per compute chunk,
  # and (mori store) each compute chunk's element name in the shared
  # parts list.
  source_deps <- new.env(parent = emptyenv())
  source_elts <- new.env(parent = emptyenv())
  # Mori store lifecycle: EVERY store region (read window or compute
  # output) is refcounted per consuming TASK and dropped the moment its
  # last consumer retires — except regions the host still needs after
  # the drain (combine partials, non-streamed sink chunks; see
  # host_keep below). Without this the store only empties at
  # end-of-run: streamed sink chunks stay pinned after they are on
  # disk and every intermediate stage's full output survives the whole
  # execution — a multi-stage tail over a 22-band cube accumulates
  # gigabytes of dead regions and OOMs where its live frontier is
  # small.
  task_ins <- new.env(parent = emptyenv())       # task -> store deps consumed
  store_users <- new.env(parent = emptyenv())    # task -> n consumers left
  task_stage_of <- new.env(parent = emptyenv())  # task -> store stage id
  stage_store_mb <- new.env(parent = emptyenv()) # read stage -> window MB

  # Compute-on-read (phase 12b, CPU only): a compute stage with ONE
  # input stage — a source read consumed by nobody else — and a
  # single export can execute inside the source's read tasks: the
  # kernel runs once per read window and only its OUTPUT is stored
  # and split. The per-chunk task fleet for source-fed kernel chains
  # (mask cleanup: 330 tasks on the benchmark) disappears, with its
  # dispatch, extract, upload and store round-trips. WHICH eligible
  # chains fuse is the placement pass's decision (R/placement.R),
  # returned as a side table the task build consumes.
  # Shape the compute pool for THIS plan before costing placement
  # against it (scan plans get fat masks, kernel fleets narrow ones).
  plan_has_scan <- any(vapply(plan@stages, function(s)
    any(vapply(s@members, function(id)
      S7::S7_inherits(graph_get(graph, id), ScanNode), logical(1))),
    logical(1)))
  # Scan confinement: the first K = garry.scan_profiles profiles are
  # designated for scan tasks; pick_comp_prof routes them nowhere
  # else, so scan live/retained memory is K x working set by
  # construction (workstream B).
  scan_profs <- if (plan_has_scan)
    comp_profs[seq_len(min(as.integer(garry_opt("scan_profiles")),
                           length(comp_profs)))] else character(0)
  .comp_pool_shape(n_comp, plan_has_scan, n_scan = length(scan_profs))
  placement <- .plan_placement(plan, consumers_of, warp_only,
                               n_read = n_read, n_comp = n_comp,
                               reader_threads = .garry_state$reader_threads,
                               comp_threads = .garry_state$comp_threads,
                               avail_mb = .garry_ram_avail_mb(),
                               mode = garry_opt("placement"))
  fuse_of <- placement$by_source     # source sid -> fuse spec
  fused_cid <- placement$fused       # fused compute sid -> TRUE

  # Jit warm-up specs, one per compute stage: the modal
  # (full) chunk shape, compiled on every compute daemon at run start.
  warm_specs <- list()

  # Task insertion follows the launch-order invariant: the ready-queue
  # scan below launches pending tasks in insertion order, so sibling
  # producer subtrees (e.g. per-band reads) enqueue contiguously and
  # each band's fused tail overlaps the next band's read drain.
  for (s in plan@stages[.stage_launch_order(plan)]) {
    if (s@kind == "reduce_combine") next
    if (s@kind == "source_read" && warp_only[[s@id]]) next
    if (!is.null(fused_cid[[.key(s@id)]])) next   # runs on its read
    it <- chunk_iter(s@chunks)

    if (s@kind %in% c("source_read", "warp")) {
      if (s@kind == "warp") {
        wnode <- graph_get(graph, s@members[[1L]])
        snode <- graph_get(graph, wnode@parents[[1L]])
        vrt <- gdal_warp_vrt(snode@path, snode@band, wnode@target_grid,
                             wnode@resampling, src_nodata = snode@nodata)
        rpath <- vrt; rband <- 1L; rnodata <- snode@nodata
        roo <- character(0)
        rsc <- snode@scale; rof <- snode@offset
      } else {
        node <- graph_get(graph, s@members[[1L]])
        rpath <- .gti_resampled_path(node@path, node@resampling)
        rband <- node@band; rnodata <- node@nodata
        roo <- node@open_options
        rsc <- node@scale; rof <- node@offset
      }
      skey <- .key(s@members[[1L]])
      fspec <- fuse_of[[.key(s@id)]]
      oid <- s@id                    # store identity: fused stage id
      if (!is.null(fspec)) {
        oid <- fspec$cid
        skey <- fspec$out_key
      }
      # Raw read gate (D21): halo-free windows whose consumers see f32
      # values — the node's own dtype for pure reads, the fused
      # kernel's input dtype for compute-on-read. Non-f32 dtypes keep
      # the matrix path (bitwise consumers, integer exactness).
      raw_in <- use_raw && s@chunks@halo == 0L &&
        identical(if (is.null(fspec)) {
          graph_get(graph, s@members[[1L]])@grid@dtype
        } else {
          fspec$dtype
        }, "f32")
      fetch_deps <- character(0)
      read_pool <- "read"
      # A FUSED read's kernel working set rides the in-flight compute
      # byte budget (see comp_ok): the placement pass estimated it.
      task_mb_read <- if (!is.null(fspec)) fspec$ws_mb %||% 0 else 0
      if (s@kind == "source_read") {
        fp <- prepare_fetch(rpath, roo, rnodata, s@grid)
        if (!is.null(fp)) {
          fetch_deps <- fp$deps
          rpath <- fp$local
          fetch_files_of[[.key(s@id)]] <- fp$files
          # Fetch-backed assembles are local CPU (warp + any fused
          # kernel): route them to the compute pool, which idles
          # during the drain now that compute-on-read emptied it of
          # per-chunk mask tasks — band 1 assembles DURING band 2's
          # fetches and the read pool never stops downloading.
          read_pool <- "comp"
          task_mb_read <- max(
            task_mb_read,
            prod(pmin(as.numeric(s@chunks@chunk_dim),
                      as.numeric(s@grid@dims[c("x", "y")]))) * 24 / 2^20)
        }
      }
      # Bytes this read pins in the store from launch until its last
      # consumer retires (raw f32 payloads, R doubles otherwise). The
      # launch gate budgets against the sum of these, not the task
      # count: a read fleet costs residency, not concurrency. A
      # coalesced multi-band window pins every band plane in ONE
      # region, so the outer-dim product multiplies in. A FUSED read
      # stores only the kernel's export (core + out_pad ring): price
      # the export's planes, or a fused multi-band read is over-charged
      # by the band count and the budget serialises the fleet.
      store_mb_read <- if (is.null(fspec)) {
        .store_region_mb(s@chunks@chunk_dim, s@grid@dims, s@chunks@halo,
                         .node_outer_nb(graph, s@members[[1L]]),
                         .store_bytes_of(
                           graph_get(graph, s@members[[1L]])@grid@dtype,
                           use_raw))
      } else {
        .store_region_mb(s@chunks@chunk_dim, s@grid@dims,
                         fspec$out_pad %||% 0L, fspec$out_nb %||% 1,
                         .store_bytes_of(fspec$out_dtype %||% "f32",
                                         use_raw))
      }
      stage_store_mb[[.key(oid)]] <- store_mb_read
      split_cg <- .exec_split_cg(plan, s, consumers_of[[s@id]])
      if (is.null(split_cg)) {
        if (length(fetch_deps))
          fetch_reads_left[[.key(s@id)]] <- nrow(it)
        if (!is.null(fspec))
          source_deps[[.key(oid)]] <-
            sprintf("s%d_c%d", s@id, seq_len(nrow(it)))
        for (j in seq_len(nrow(it))) {
          local({
            sid <- s@id; jj <- j; cg <- s@chunks; core <- it[jj, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            fs <- fspec; oid2 <- oid; rr <- raw_in; sr <- use_raw
            sc <- rsc; of <- rof
            key <- sprintf("s%d_c%d", sid, jj)
            add_task(key, fetch_deps, read_pool, mb = task_mb_read,
                     store_mb = store_mb_read,
                     launch = function(prof) {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, open_options = oo,
                                              fuse = fs, read_raw = rr,
                                              store_raw = sr,
                                              scale = sc, offset = of),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core, k2 = k2,
                oo = oo, reg = sprintf("r%d_%s", run_id, key), fs = fs,
                rr = rr, sr = sr, sc = sc, of = of,
                .compute = prof)
            })
            task_stage_of[[key]] <- oid2
          })
        }
      } else {
        # Coarse reads. RDS store: split into per-compute-chunk files on
        # write. Mori store: share the whole read buffer; consumers
        # slice their window zero-copy. Either way compute chunk j's
        # dependency is the READ task covering it.
        its <- chunk_iter(split_cg)
        # A fused kernel consumes the halo; its output carries the
        # fused stage's out_pad ring (D22), 0 in the common case.
        H2 <- if (is.null(fspec)) 2L * split_cg@halo
              else 2L * (fspec$out_pad %||% 0L)
        dep_of <- character(nrow(its))
        elt_of <- sprintf("%s\x1f%d", skey, seq_len(nrow(its)))
        if (length(fetch_deps))
          fetch_reads_left[[.key(s@id)]] <- nrow(it)
        for (r in seq_len(nrow(it))) {
          members <- .exec_split_members(its, it[r, ])
          dep_of[members] <- sprintf("s%d_r%d", s@id, r)
          local({
            sid <- s@id; rr2 <- r; cg <- s@chunks; core <- it[rr2, ]
            p2 <- rpath; b2 <- rband; nd <- rnodata; k2 <- skey; oo <- roo
            fs <- fspec; oid2 <- oid; rr <- raw_in; sr <- use_raw
            sc <- rsc; of <- rof
            key <- sprintf("s%d_r%d", sid, rr2)
            # Parts carry the stage halo (see .exec_split_cg): same
            # r0/c0, slice grown by 2*halo.
            parts <- lapply(members, function(j) {
              list(r0 = its$y_off[[j]] - core$y_off,
                   c0 = its$x_off[[j]] - core$x_off,
                   nr = its$y_size[[j]] + H2, nc = its$x_size[[j]] + H2,
                   elt = elt_of[[j]])
            })
            add_task(key, fetch_deps, read_pool, mb = task_mb_read,
                     store_mb = store_mb_read,
                     launch = function(prof) {
              mirai::mirai(
                garry::.daemon_run_source_shm(p2, b2, nd, cg, core, k2,
                                              reg, parts = parts,
                                              open_options = oo,
                                              fuse = fs, read_raw = rr,
                                              store_raw = sr,
                                              scale = sc, offset = of),
                p2 = p2, b2 = b2, nd = nd, cg = cg, core = core,
                k2 = k2, oo = oo, parts = parts, fs = fs,
                rr = rr, sr = sr, sc = sc, of = of,
                reg = sprintf("r%d_%s", run_id, key),
                .compute = prof)
            })
            task_stage_of[[key]] <- oid2
          })
        }
        source_deps[[.key(oid)]] <- dep_of
        source_elts[[.key(oid)]] <- elt_of
      }

    } else {  # compute / reduce_partial
      in_meta <- .exec_in_meta(graph, s, plan@stages, node_stage)
      max_set_mb <- max(max_set_mb, sum(vapply(in_meta, function(m)
        stage_store_mb[[.key(m$id)]] %||% 0, numeric(1))))
      sig <- paste0(.stage_kernel_sig(graph, s), "@", s@device)
      okeys <- vapply(s@exports, .key, character(1))
      cd <- s@chunks@chunk_dim
      need <- s@halo + s@out_pad
      task_mb <- .stage_bytes_per_px(graph, s@members, s@input_nodes) *
        prod(as.numeric(cd) + 2 * need) / 2^20
      # The /2 discount reflects mori's zero-copy shared INPUT mappings:
      # the per-px estimate is calibrated for private R-double inputs, but
      # under mori the inputs are shared and the resident cost is mostly
      # the f32 device copies (~half). It does NOT apply to a scan stage,
      # whose cost is dominated by the body's PRIVATE live f64 state cubes,
      # not its inputs -- halving those under-counted the robust Kalman
      # tail's working set and let the budget over-admit concurrent scan
      # chunks. The planner's chunk sizing keeps the full figure.
      has_scan <- any(vapply(s@members, function(id)
        S7::S7_inherits(graph_get(graph, id), ScanNode), logical(1)))
      if (!has_scan) task_mb <- task_mb / 2
      # Scan kernels pre-warm too: the broadcast is TARGETED at the
      # K designated scan profiles only (the validated <= 2 concurrent
      # pre-drain compiles, daemon-exact at any pool width).
      warm_specs[[length(warm_specs) + 1L]] <- list(
        ck = sig,
        scan = has_scan,
        fn = s@fn,
        device = s@device,
        dtypes = vapply(in_meta, function(m) m$dtype, character(1)),
        # Outer-dim product per input: a coalesced multi-band source
        # (or a cross-stage cube intermediate) warms with the rank-3
        # shape the real chunks arrive in.
        outers = vapply(s@input_nodes, function(nid) {
          d <- .node_grid(graph_get(graph, nid))@dims
          as.integer(max(1, prod(d[!names(d) %in% c("x", "y")])))
        }, integer(1)),
        nr = min(cd[[2L]], s@grid@dims[["y"]]) + 2L * need,
        nc = min(cd[[1L]], s@grid@dims[["x"]]) + 2L * need)
      # Compute outputs pin store regions exactly like read windows —
      # from launch until the last consumer retires (or, for host_keep
      # stages, until end of run) — but previously carried store_mb = 0
      # and were invisible to the residency gate: a chain of compute
      # stages could flood the store unbudgeted.
      epads_all <- if (length(s@export_pads)) as.integer(s@export_pads)
                   else integer(length(s@exports))
      store_mb_comp <- sum(vapply(seq_along(s@exports), function(ei) {
        e <- s@exports[[ei]]
        .store_region_mb(cd, s@grid@dims, epads_all[[ei]],
                         .node_outer_nb(graph, e),
                         .store_bytes_of(graph_get(graph, e)@grid@dtype,
                                         use_raw))
      }, numeric(1)))
      stage_store_mb[[.key(s@id)]] <- store_mb_comp
      for (j in seq_len(nrow(it))) {
        local({
          sid <- s@id; jj <- j; fn <- s@fn; need <- s@halo + s@out_pad
          epads <- if (length(s@export_pads)) stats::setNames(
            as.integer(s@export_pads),
            vapply(s@exports, .key, character(1))) else integer(0)
          edge <- if (any(epads > 0L)) list(
            pads = epads[epads > 0L], core = it[jj, ],
            gdims = s@grid@dims)
          meta <- in_meta
          ck <- sig                       # content-addressed jit key
          out_keys <- okeys
          sdev <- s@device
          in_deps <- vapply(meta, function(m) {
            dep <- source_deps[[.key(m$id)]]
            if (is.null(dep)) sprintf("s%d_c%d", m$id, jj) else dep[[jj]]
          }, character(1))
          in_keys <- vapply(s@input_nodes, .key, character(1))
          # Mori store: coarse-read inputs address their part element.
          shm_keys <- vapply(seq_along(meta), function(i) {
            el <- source_elts[[.key(meta[[i]]$id)]]
            if (is.null(el)) in_keys[[i]] else el[[jj]]
          }, character(1))
          trims <- vapply(meta, function(m)
            as.integer(m$pad - need), integer(1))
          dtypes <- vapply(meta, function(m) m$dtype, character(1))
          key <- sprintf("s%d_c%d", sid, jj)
          sr <- use_raw
          add_task(key, unique(in_deps), "comp", mb = task_mb,
                   store_mb = store_mb_comp,
                   scan = has_scan,
                   dev = sdev, ck = sig,
                   launch = function(prof, with_fn = TRUE) {
            # Handles resolve at launch time: dependencies are done, so
            # `chunk_vals` holds every input's shared object (a ~30-byte
            # name over the wire). `with_fn = FALSE` sends the jit
            # cache key alone: daemons already hold every distinct
            # stage closure from the warm-up broadcast, and re-shipping
            # it costs MBs of host serialization per task (the 145-band
            # predict closure measured 3.36 MB).
            mirai::mirai(
              garry::.daemon_run_compute_shm(ck, fn, in_vals, in_keys,
                                             trims, dtypes, reg,
                                             out_keys = ok,
                                             device = dv,
                                             store_raw = sr,
                                             edge = eg),
              ck = ck, fn = if (with_fn) fn else NULL,
              in_vals = lapply(in_deps, function(d) chunk_vals[[d]]),
              in_keys = shm_keys,
              trims = trims, dtypes = dtypes,
              reg = sprintf("r%d_%s", run_id, key),
              ok = out_keys, dv = sdev, sr = sr, eg = edge,
              .compute = prof)
          })
          # Refcount every store input this task consumes (read windows
          # AND upstream compute outputs); a region frees when its last
          # consuming task retires.
          rk <- unique(in_deps)
          task_ins[[key]] <- rk
          for (r2 in rk)
            store_users[[r2]] <- (store_users[[r2]] %||% 0L) + 1L
          task_stage_of[[key]] <- sid
        })
      }
    }
  }

  # Store bytes currently pinned by launched-but-unreleased regions:
  # read windows AND compute outputs (both live in the mori store from
  # launch until their last consumer retires).
  mb_store_resident <- 0

  # host_keep (filled after the streaming-sink setup below): store
  # stage ids whose regions the host must read AFTER the drain —
  # combine partials and any sink assembled host-side rather than
  # streamed. Everything else drops as its consumers retire.
  host_keep <- new.env(parent = emptyenv())

  # Drops are batched per harvest sweep: one .daemon_shm_drop round
  # per pool instead of one per retiring task.
  pending_drop <- character(0)
  pending_drop_mb <- 0
  queue_drop <- function(keys) {
    for (rk in keys) {
      if ((store_users[[rk]] %||% 0L) > 0L) next
      sid <- task_stage_of[[rk]]
      if (is.null(sid)) next                       # no store region (fetch)
      if (isTRUE(host_keep[[.key(sid)]])) next
      task_stage_of[[rk]] <- NULL                  # drop at most once
      mb_store_resident <<- mb_store_resident - (tasks[[rk]]$store_mb %||% 0)
      pending_drop <<- c(pending_drop, rk)
      pending_drop_mb <<- pending_drop_mb + (tasks[[rk]]$store_mb %||% 0)
    }
    invisible(NULL)
  }
  # Throttled: the host gc() that releases mori mappings costs seconds
  # on a large host heap, so drops flush on a clock, not per sweep.
  # Budget ACCOUNTING (mb_store_resident) is decremented at queue time,
  # so read launches unblock immediately; only the physical unlink
  # lags, bounded by the flush interval — and by BYTES: once the
  # queued-but-unfreed regions exceed a quarter of the read budget,
  # flush regardless of the clock, or true shm high-water exceeds the
  # budget by everything launched inside one flush window.
  last_flush <- Sys.time()
  flush_drops <- function(force = FALSE) {
    if (length(pending_drop) == 0L) return(invisible(NULL))
    if (!force &&
        pending_drop_mb < 0.25 * read_budget_mb &&
        difftime(Sys.time(), last_flush, units = "secs") < 5)
      return(invisible(NULL))
    for (p in profiles)
      try(mirai::everywhere(garry::.daemon_shm_drop(regs),
                            regs = sprintf("r%d_%s", run_id, pending_drop),
                            .compute = p),
          silent = TRUE)
    # Per-key exists() filter: ls() on the store env sorts every key
    # (~40 ms at 20k entries) once per flush.
    rm(list = pending_drop[vapply(pending_drop, exists,
                                  logical(1), envir = chunk_vals,
                                  inherits = FALSE)],
       envir = chunk_vals)
    pending_drop <<- character(0)
    pending_drop_mb <<- 0
    last_flush <<- Sys.time()
    gc(FALSE)   # host munmaps its handles; regions free once unlinked
    invisible(NULL)
  }

  # On task completion: the task's own output may already be dead (a
  # streamed sink chunk with no compute consumers), and each store
  # input it consumed loses one user.
  release_store <- function(k) {
    queue_drop(k)
    deps <- task_ins[[k]]
    if (is.null(deps) || length(deps) == 0L) return(invisible(NULL))
    for (rk in deps)
      store_users[[rk]] <- store_users[[rk]] - 1L
    queue_drop(deps)
  }

  # Pre-drain jit warm-up: compile each compute stage's modal shape on
  # every compute-pool daemon while the read pool owns the drain
  # (measured: cold 1.45 s vs warmed 0.61 s per tail chunk). Fired
  # async — a daemon runs it before any compute task queued after it;
  # while the read pool owns the early drain; the handle stays
  # referenced until the run ends.
  warm_handle <- NULL
  if (isTRUE(garry_opt("jit_warmup")) && length(warm_specs)) {
    # Content-addressed keys collapse structurally identical stages
    # (e.g. per-slice mask cleanup) to ONE spec. Targeted warm-up: map
    # kernels on every profile, scan kernels only at the designated
    # scan profiles. Warmth is recorded PER PROFILE — key-only
    # launches are exact, not probabilistic (the resend covers a
    # profile whose warm-up failed, clearing its mark).
    warm_specs <- warm_specs[!duplicated(
      vapply(warm_specs, `[[`, character(1), "ck"))]
    scan_sp <- Filter(function(sp) isTRUE(sp$scan), warm_specs)
    map_sp <- Filter(function(sp) !isTRUE(sp$scan), warm_specs)
    wh <- list()
    for (p in comp_profs) {
      sp_p <- c(map_sp, if (p %in% scan_profs) scan_sp)
      if (!length(sp_p)) next
      wh <- c(wh, mirai::everywhere(garry::.daemon_warm_jit(sp),
                                    sp = sp_p, .compute = p))
      for (sp in sp_p) prof_warm[[.pw_key(p, sp$ck)]] <- TRUE
    }
    warm_handle <- wh
  }

  # Region-aware stage chunk lookup. A stage's chunks live under its
  # own task keys UNLESS source_deps says otherwise: a FUSED stage's
  # chunks ride its source's read tasks, and an UNFUSED coarse-split
  # source's chunks are elements of its read-window regions — both
  # store per-chunk data under READ task keys. Everything that
  # retrieves stage chunks by (stage, j) — the streaming writers, the
  # post-drain assembly, in-memory multi-export — goes through here.
  # (Gating this on the placement table lost SPLIT source sinks:
  # defect hunt H1, 2026-07-30.)
  chunk_of <- function(sid, j) {
    deps <- source_deps[[.key(sid)]]
    if (is.null(deps)) return(chunk_vals[[sprintf("s%d_c%d", sid, j)]])
    v <- chunk_vals[[deps[[j]]]]
    el <- source_elts[[.key(sid)]]
    if (is.null(el)) v
    else stats::setNames(list(v[[el[[j]]]]), sub("\x1f.*$", "", el[[j]]))
  }
  # Un-extracted form for writer-daemon dispatch: the SHARED value (a
  # ~30-byte region name over the wire), the element to extract on the
  # daemon, and the store region key the write consumes.
  chunk_ref <- function(sid, j) {
    deps <- source_deps[[.key(sid)]]
    if (is.null(deps)) {
      rk <- sprintf("s%d_c%d", sid, j)
      return(list(v = chunk_vals[[rk]], el = NULL, rk = rk))
    }
    el <- source_elts[[.key(sid)]]
    list(v = chunk_vals[[deps[[j]]]],
         el = if (!is.null(el)) el[[j]], rk = deps[[j]])
  }
  # Task -> sink chunk map for a streaming writer: which chunks of
  # stage `st_id` land when task `key` completes. One chunk per task
  # for ordinary stages; a fused stage under a coarse read lands ALL of
  # a read window's chunks at once.
  sink_task_map <- function(st_id, n_chunks) {
    deps <- source_deps[[.key(st_id)]]
    keys <- if (is.null(deps))
      sprintf("s%d_c%d", st_id, seq_len(n_chunks)) else deps
    split(seq_len(n_chunks), keys)
  }

  # Streaming sink writes (phase 11.3): with a file destination, each
  # sink chunk writes the moment it lands, so all but the last band's
  # writes hide under the drain instead of running serially after it.
  # (On error the partially written file is left behind; the
  # single-threaded executor still writes at the end.)
  sink <- plan@stages[[plan@sink]]
  wnodata <- if (is.null(nodata)) numeric(0) else as.numeric(nodata)
  multi <- length(plan@sinks) > 1L
  stream_write <- !is.null(path) && sink@kind != "reduce_combine" && !multi
  # Streamed writes go to the writer daemon when the pool has one: the
  # host creates the outputs (geometry, bands, nodata), closes its
  # handles, and ships each landed chunk's REGION NAME to the writer —
  # the f64->file conversion transients then live in one reapable
  # process instead of on the dispatch thread (measured 15-19 GB of
  # oscillating host anon on a 4.2 Mpx multi-export scan tail).
  writer_on <- (stream_write || (!is.null(path) && multi)) &&
    tryCatch(.gd_n_compute("garry_write") > 0L, error = function(e) FALSE)
  if (writer_on)
    # Abort path: queued writer tasks still map store regions by name,
    # so this handler must run BEFORE the earlier-registered
    # .daemon_shm_clear handler unlinks them (`after = FALSE` prepends;
    # on.exit otherwise runs in registration order). Await the queued
    # writes with errors tolerated — the run has already failed; the
    # writes either land or fail quietly — then close the writer's
    # handles so the partial output is closed and deletable.
    on.exit({
      try(for (w in wr_inflight) mirai::call_mirai(w$h), silent = TRUE)
      try(mirai::everywhere(garry::.daemon_write_close(),
                            .compute = "garry_write"),
          silent = TRUE)
    }, add = TRUE, after = FALSE)
  sink_ds <- NULL
  if (stream_write) {
    sink_skey <- .key(sink@members[[length(sink@members)]])
    sink_it <- chunk_iter(sink@chunks)
    sink_spad <- .exec_export_pad(sink, sink@members[[length(sink@members)]])
    sink_task_j <- sink_task_map(sink@id, nrow(sink_it))
    sink_ds <- gdal_create_output(path, sink@grid, nodata = wnodata,
                                  band_names = band_names,
                                  dtype = wspec$dtype,
                                  options = wspec$options,
                                  scale = wspec$scale %||% numeric(0),
                                  offset = wspec$offset %||% numeric(0))
    if (writer_on) { sink_ds$close(); sink_ds <- NULL }
    on.exit(if (!is.null(sink_ds)) try(sink_ds$close(), silent = TRUE),
            add = TRUE)
  }
  # Multi-export streaming: every non-combine sink gets its own open
  # output and writes each chunk the moment its stage task lands (for
  # a FUSED sink stage: the moment its source's read task lands).
  # reduce_combine sinks (host-side combines) write after the drain.
  stream_sinks <- list()
  if (!is.null(path) && multi) {
    for (kk in seq_along(plan@sinks)) {
      nid <- plan@sinks[[kk]]
      nm <- names(plan@sinks)[[kk]]
      st <- plan@stages[[max(which(vapply(plan@stages, function(s)
        nid %in% s@members, logical(1))))]]
      if (st@kind == "reduce_combine") next
      p <- if (length(path) == 1L && dir.exists(path))
        file.path(path, paste0(nm, ".tif")) else path[[nm]]
      ngrid <- graph_get(plan@graph, nid)@grid
      it <- chunk_iter(st@chunks)
      ds <- gdal_create_output(p, ngrid, nodata = wnodata,
                               band_names = .sink_band_names(band_names,
                                                             nm, ngrid),
                               dtype = wspec$dtype,
                               options = wspec$options,
                               scale = wspec$scale %||% numeric(0),
                               offset = wspec$offset %||% numeric(0))
      if (writer_on) { ds$close(); ds <- NULL }
      stream_sinks[[nm]] <- list(
        sid = st@id,
        key = .key(nid), it = it, pad = .exec_export_pad(st, nid), ds = ds,
        dtype = wspec$dtype %||% ngrid@dtype, path = p,
        task_j = sink_task_map(st@id, nrow(it)))
    }
    on.exit(for (sp in stream_sinks)
      if (!is.null(sp$ds)) try(sp$ds$close(), silent = TRUE),
      add = TRUE)
  }

  # Post-drain needs: combine closures run host-side on their partial
  # stage's chunks, and any sink NOT covered by a streaming writer is
  # assembled host-side from its stage's chunks. Those stages' regions
  # must survive consumer refcounting; everything else is dropped as
  # the frontier passes.
  for (s in plan@stages)
    if (s@kind == "reduce_combine")
      host_keep[[.key(s@inputs[[1L]])]] <- TRUE
  sink_nids <- if (length(plan@sinks) > 0L) plan@sinks
    else sink@members[[length(sink@members)]]
  for (nid in unique(sink_nids)) {
    st <- plan@stages[[max(which(vapply(plan@stages, function(s)
      nid %in% s@members, logical(1))))]]
    if (st@kind == "reduce_combine") next          # parts kept above
    streamed <- (stream_write && st@id == sink@id) ||
      (multi && !is.null(path) &&
         names(plan@sinks)[match(nid, plan@sinks)] %in% names(stream_sinks))
    if (!streamed) host_keep[[.key(st@id)]] <- TRUE
  }

  # Effective read budget: never below 1.25x the widest stage's
  # co-resident window set (see max_set_mb above).
  read_budget_mb <- max(read_budget_mb, 1.25 * max_set_mb)

  # ---- Memory admission control -------------------------------------
  # The configured budgets are CAPS, not entitlements. `ram_budget_mb x
  # pool` assumes the machine is garry's alone; when the calling session
  # already holds tens of GB (model fits, point tables, a previous
  # stage's outputs) that overcommits and the run dies mid-drain. Fit
  # both budgets inside a fraction of what is ACTUALLY available, and
  # re-read during the drain so a host that grows while we run tightens
  # the gates rather than racing it to the OOM killer.
  #
  # Floors keep progress possible: compute always admits its largest
  # single task (the in-flight gates already allow one over-budget task
  # through), and reads always admit one window. A budget below those
  # serialises rather than deadlocks.
  mem_frac <- garry_opt("exec_ram_fraction")
  comp_budget_cfg <- comp_budget_mb
  read_budget_cfg <- read_budget_mb
  task_mb_max <- 0
  for (k in ls(tasks)) {
    t2 <- tasks[[k]]
    if (identical(t2$pool, "comp")) task_mb_max <- max(task_mb_max, t2$mb %||% 0)
  }
  store_mb_max <- max(c(0, vapply(ls(stage_store_mb), function(k)
    stage_store_mb[[k]] %||% 0, numeric(1))))
  mem_last_check <- Sys.time()
  rss_excess_seen <- 0
  # Fleet anon at RUN START, plus a trailing window of unmanaged samples
  # (dask's managed / unmanaged-old / unmanaged-recent distinction).
  # Daemons legitimately RETAIN memory between tasks — XLA buffer pools;
  # a warmed scan daemon holds ~6.5 GB — and that retained pool is
  # REUSED by the next task, not additive to it. The first SI run of the
  # correction compared measured anon against in-flight bytes alone, so
  # warmed standing state read as drift, the budget floored mid-tail and
  # the scans serialised (2026-07-31). The correction therefore
  # tolerates the run-start baseline AND anything sustained across the
  # trailing window (~30 s at the 5 s refresh cadence): only RECENT
  # growth beyond what in-flight work explains tightens the budget —
  # which is exactly the estimate-defect class (a burst of
  # underestimated working sets) it exists to catch. The shm clamp and
  # the avail-RAM pool remain the hard backstops for slow leaks.
  rss_baseline <- .garry_fleet_anon_mb(.garry_state$pool_pids)
  if (!is.finite(rss_baseline)) rss_baseline <- 0
  rss_hist <- rep(NA_real_, 6L)   # trailing (anon - inflight) samples
  refresh_mem_budgets <- function(announce = FALSE) {
    avail <- .garry_ram_avail_mb()
    if (is.na(avail) || !is.finite(mem_frac) || mem_frac <= 0) return(invisible(NULL))
    pool <- avail * mem_frac
    # Reads are cheap to hold and expensive to redo; give them at most a
    # third of the pool, compute the rest.
    rb <- max(store_mb_max, min(read_budget_cfg, pool / 3))
    cb <- max(task_mb_max, min(comp_budget_cfg, pool - rb))
    # /dev/shm ground truth backstop: the resident-byte accounting is
    # an estimate decremented at queue-drop time, so physical
    # high-water can run ahead of it within a flush window, and other
    # tmpfs consumers (the fetch cache, other processes) share the
    # mount. Clamp the store budget so resident + admissible fits in
    # what /dev/shm actually has free, and force the queued drops out
    # when free space breaches the headroom. tmpfs pages charge the
    # creating process's CGROUP (a systemd-run scope counts them
    # against MemoryMax while host df still shows free space), so the
    # effective free space is the MINIMUM of the mount and the cgroup
    # headroom — without the cgroup term the backstop never fires
    # inside a confined run and the scope thrashes at its ceiling.
    shm_free <- .garry_shm_free_mb()
    cg_free <- .garry_cgroup_avail_mb()
    if (!is.na(cg_free))
      shm_free <- if (is.na(shm_free)) cg_free else min(shm_free, cg_free)
    if (is.finite(shm_free)) {
      headroom <- garry_opt("shm_headroom_mb")
      rb <- min(rb, max(store_mb_max,
                        mb_store_resident + shm_free - headroom))
      if (shm_free < headroom) flush_drops(force = TRUE)
    }
    # Measured per-daemon memory correction (dask's managed-vs-process
    # distinction, transplanted into the admission model): when the
    # fleet's measured anonymous RSS exceeds the modelled in-flight
    # working sets plus a per-daemon client allowance, some estimate is
    # drifting low — shrink the compute budget by the excess, so the
    # next estimate defect becomes a throughput dip and a log line
    # instead of an OOM. mb_inflight is initialised after the first
    # (announce) refresh, hence the exists() guard; the inform is
    # throttled to genuine growth so a persistently tight run does not
    # spam every 5 s refresh.
    anon <- .garry_fleet_anon_mb(.garry_state$pool_pids)
    if (is.finite(anon) && isTRUE(garry_opt("rss_correction"))) {
      infl <- if (exists("mb_inflight")) mb_inflight else 0
      allow <- length(.garry_state$pool_pids) *
        garry_opt("cost_xla_client_mb")
      unman <- anon - infl
      old_unman <- suppressWarnings(min(rss_hist, na.rm = TRUE))
      if (!is.finite(old_unman)) old_unman <- rss_baseline
      tolerated <- max(rss_baseline, old_unman)
      excess <- unman - (tolerated + allow)
      rss_hist <<- c(rss_hist[-1L], unman)
      if (excess > 0) {
        cb <- max(task_mb_max, cb - excess)
        if (excess > 1.2 * rss_excess_seen) {
          rss_excess_seen <<- excess
          cli::cli_inform(paste0(
            "garry: fleet anon RSS {round(anon)} MB exceeds modelled ",
            "{round(infl + tolerated + allow)} MB (recent growth ",
            "{round(excess)} MB); compute budget tightened to ",
            "{round(cb)} MB"))
        }
      }
    }
    # Announce only on a genuine squeeze: reads capped below their
    # configured budget, or the pool cannot hold even two compute chunks.
    # (comp_budget_cfg is Inf by default -- compute is RAM-pool-driven --
    # so a bare "cb < cfg" would fire every refresh.)
    if (announce && (rb < read_budget_cfg ||
                     (task_mb_max > 0 && cb < 2 * task_mb_max)))
      cli::cli_inform(paste0(
        "garry: {round(avail/1024, 1)} GiB available; in-flight compute ",
        "budget {round(cb)} MB, resident reads {round(rb)} MB (configured ",
        "{round(read_budget_cfg)})"))
    comp_budget_mb <<- cb
    read_budget_mb <<- rb
    invisible(NULL)
  }
  refresh_mem_budgets(announce = TRUE)
  # A single task that cannot fit even the whole pool is a planning
  # problem (chunks too big), not a scheduling one: it will run, alone,
  # but say so rather than let it look like a mysterious stall or kill.
  local({
    avail <- .garry_ram_avail_mb()
    if (!is.na(avail) && task_mb_max > avail * mem_frac) {
      chunk_sz <- .garry_fmt_mb(task_mb_max)
      budget_sz <- .garry_fmt_mb(avail * mem_frac)
      cli::cli_warn(paste0(
        "a single compute chunk is estimated at {chunk_sz}, above the ",
        "{budget_sz} execution budget; ",
        "it will run one at a time. Lower {.code garry.chunk_target_px} or ",
        "{.code garry.ram_budget_mb} to chunk finer."))
    }
  })

  # Scan order: priority first (stable within a priority level), then
  # WINDOW-major within a priority: tasks sharing a chunk/window
  # ordinal sort together across sibling stages. Insertion order is
  # stage-major (band 1's windows, band 2's windows, ...), so a
  # multi-input stage's per-window input set would otherwise only
  # complete after nearly the whole stage's reads launched — under the
  # read byte budget that degrades to a serial trickle. Window-major
  # makes each window's cross-band set resident and releasable as a
  # unit, and lands the same source window's per-band reads together
  # in time, so pixel-interleaved sources decompress each window ~once
  # per reader (GDAL block cache) instead of once per band.
  # Fetch tasks are prio 1, everything else 2, so the read pool
  # downloads flat-out while any fetch is pending and only then
  # takes assembles — interleaving them measured the fleet at
  # ~18 MB/s where pure fetching sustains 40-50 MB/s (a local
  # assemble idles its reader's connection for ~1 s).
  task_keys <- ls(tasks)
  ord_win <- vapply(task_keys, function(k) {
    n <- suppressWarnings(as.integer(sub("^s\\d+_[rc](\\d+)$", "\\1", k)))
    if (is.na(n)) 0L else n
  }, integer(1))
  ord_prio <- vapply(task_keys, function(k) tasks[[k]]$prio, integer(1))
  ord_seq <- vapply(task_keys, function(k) tasks[[k]]$seq, integer(1))
  task_order <- task_keys[order(ord_prio, ord_win, ord_seq)]

  # Polling ready-queue with per-pool in-flight caps; compute
  # launches additionally gated by the byte budget (always at least
  # one runs, so a single over-budget task cannot deadlock). Pools are
  # strict: read-tagged tasks run on read daemons, comp-tagged on the
  # compute pool. Compute tasks never spill onto readers -- a spilled
  # task would load anvl on a lean reader and spin up a whole all-cores
  # XLA client there, reintroducing the thread contention and unbounded
  # per-daemon working set a small compute pool exists to avoid.
  inflight <- list()
  n_inflight <- c(read = 0L, comp = 0L)   # by task TAG (byte budget)
  n_slot <- c(read = 0L, comp = 0L)       # by launched PROFILE slot
  mb_inflight <- 0
  # Launches self-limit on RESIDENT store bytes, not in-flight count:
  # a store region (read window or compute output) lives until its
  # last consumer retires, so a plan with many independent read stages
  # (per-year predictions in one collect) would otherwise drain its
  # entire read fleet into RAM long before the first compute stage
  # released any of it, and a chain of compute stages could pile
  # outputs unbudgeted. The escape hatch is "no read in flight", so a
  # stage whose own input set exceeds the budget still makes progress
  # one region at a time rather than deadlocking. host_keep regions
  # (non-streamed sinks, combine partials) never release mid-run, so
  # their bytes squeeze the gate as the run progresses; that is real
  # tmpfs pressure, and the floor at store_mb_max keeps the tail
  # serial rather than stuck.
  read_ok <- function(t) {
    n_inflight[["read"]] == 0L ||
      mb_store_resident + t$store_mb <= read_budget_mb
  }
  # Store-bearing COMPUTE launches get their own escape hatch. Sharing
  # read_ok's "no read in flight" escape starved the drain: reads sort
  # earlier in the launch order, so whenever the escape opened a read
  # took it, compute never launched over budget, and the regions only
  # compute retirement can free accumulated to the memory ceiling
  # (measured: crop=2048 SI bench pinned its 24G scope at task ~70 and
  # hung on tmpfs reclaim). With its own escape, at least one compute
  # task always drains a saturated store.
  store_ok_comp <- function(t) {
    n_inflight[["comp"]] == 0L ||
      mb_store_resident + t$store_mb <= read_budget_mb
  }
  # The in-flight BYTE budget covers every byte-accounted task, not
  # just comp-pool ones: a FUSED read runs its kernel's whole working
  # set on the reader, so it is compute in disguise and must ride the
  # same budget (a fleet of cold fused reads otherwise stacks N XLA
  # ramps on whatever else holds the machine — measured at crop=0 with
  # the lazy_cog staging resident). The escape is accordingly "nothing
  # byte-accounted in flight", so one over-budget task always runs.
  # (The cold-scan byte surcharge that once rode in here was retired
  # with the anonymous pool: cold-scan concurrency is bounded
  # STRUCTURALLY — K scan profiles, one cold compile per profile —
  # which two field miscalibrations proved stronger than a byte proxy;
  # design/routed-dispatch.md.)
  comp_ok <- function(t) {
    # The optional hard count cap applies to COMPUTE-POOL tasks only:
    # fused reads ride comp_ok for the byte budget but never count
    # toward the compute in-flight tally, so capping them against it
    # throttled ready reads for no resource reason (defect hunt L1).
    if (!is.null(cap_comp_opt) && identical(t$pool, "comp") &&
        n_inflight[["comp"]] >= cap_comp_opt) return(FALSE)
    mb_inflight == 0 ||
      mb_inflight + t$mb <= comp_budget_mb
  }
  # O(1) readiness: per-task unmet-dep counters decremented through a
  # reverse index on completion. The old `all(deps %in% done)` re-hashed
  # the done set for every pending task every sweep — O(tasks^2 x deps)
  # over the drain, which at ~10^4 tasks (a 22-year multi-band predict)
  # costs the host more than the tasks themselves.
  # Writer-daemon bookkeeping. Each dispatched write holds a consumer
  # reference on the producing store region (the writer maps it by
  # name), released when the write task resolves — so regions free on
  # exactly the same refcount discipline as compute consumers.
  wr_inflight <- list()
  wr_seq <- 0L
  dispatch_write <- function(sid, j, wpath, it, skey, pad, dtype) {
    ref <- chunk_ref(sid, j)
    store_users[[ref$rk]] <- (store_users[[ref$rk]] %||% 0L) + 1L
    wr_seq <<- wr_seq + 1L
    wr_inflight[[as.character(wr_seq)]] <<- list(
      rk = ref$rk,
      h = mirai::mirai(
        garry::.daemon_write_chunk(wpath, xo, yo, val, skey, el, pad,
                                   dtype, nodata = nd, n_chunks = nc,
                                   scale = wsc, offset = wof),
        wpath = wpath, xo = it$x_off[[j]], yo = it$y_off[[j]],
        val = ref$v, skey = skey, el = ref$el, pad = pad,
        dtype = dtype, nd = wnodata, nc = nrow(it),
        wsc = wspec$scale %||% numeric(0),
        wof = wspec$offset %||% numeric(0),
        .compute = "garry_write"))
    invisible(NULL)
  }
  harvest_writes <- function() {
    any_done <- FALSE
    for (wk in names(wr_inflight)) {
      w <- wr_inflight[[wk]]
      if (mirai::unresolved(w$h)) next
      if (inherits(w$h$data, c("miraiError", "errorValue")))
        cli::cli_abort(
          "sink write failed on the writer daemon: {as.character(w$h$data)}",
          class = c("garry_write_error", "garry_error"),
          region = w$rk)
      store_users[[w$rk]] <- store_users[[w$rk]] - 1L
      queue_drop(w$rk)
      wr_inflight[[wk]] <<- NULL
      any_done <- TRUE
    }
    any_done
  }

  # Cold-kernel slow start. A kernel the warm-up did not cover
  # compiles on each daemon's first task of it, and an XLA compile can
  # hold multi-GB privately (an unrolled scan measured 6-12 GB).
  # Admission prices working sets, not compiles, so without a ramp a
  # wide pool starts N simultaneous cold compiles the moment such a
  # stage becomes ready. Allow one more in-flight task of a cold
  # kernel than have ever COMPLETED: the ramp is 1, 2, 3, ... and by
  # mid-ramp the early daemons hold the kernel warm.
  dep_left <- new.env(parent = emptyenv())    # task -> unmet dep count
  dependents <- new.env(parent = emptyenv())  # task -> tasks waiting on it
  for (k in task_keys) {
    d <- unique(tasks[[k]]$deps)
    dep_left[[k]] <- length(d)
    for (dk in d) dependents[[dk]] <- c(dependents[[dk]], k)
  }
  n_done <- 0L
  is_ready <- function(k) dep_left[[k]] == 0L
  remaining <- function() n_done < n_total
  progress <- isTRUE(garry_opt("progress"))
  task_log <- garry_opt("task_log")
  # Task-log schema (locked; garry_task_report() is the reader):
  #   time,event,key,pool,slot,mb,store_mb,ready
  # launch rows carry pool/slot, the admission-priced working set and
  # store bytes, and the READY timestamp (deps satisfied) so queue-wait
  # separates from run time; rss rows sample one daemon's anon MB
  # (key = pid); model rows sample the modelled in-flight/resident MB.
  log_line <- if (is.null(task_log)) function(...) NULL else {
    if (!file.exists(task_log) || file.size(task_log) == 0)
      cat("time,event,key,pool,slot,mb,store_mb,ready\n",
          file = task_log, append = TRUE)
    function(event, key, pool = "", slot = "", mb = "", store_mb = "",
             ready = "")
      cat(sprintf("%.3f,%s,%s,%s,%s,%s,%s,%s\n", unclass(Sys.time()),
                  event, key, pool, slot, mb, store_mb, ready),
          file = task_log, append = TRUE)
  }
  t_drain0 <- unclass(Sys.time())   # zero-dep tasks are ready at drain start
  n_total <- length(tasks)
  last_report <- Sys.time()
  # Launch cursor: window-major ordering makes launches near-sequential,
  # so each sweep scans from the first still-pending task instead of the
  # whole order (O(frontier), not O(n), per sweep).
  first_pending <- 1L
  # Launch state only changes at harvest (slots, byte budgets and dep
  # counters are all freed/decremented there; a launch itself can only
  # CONSUME capacity), so a sweep that harvested nothing can never
  # launch anything the previous sweep could not: skip the scan
  # entirely on those iterations instead of walking every pending
  # task per 2 ms poll (measured 16.8 ms/sweep at 20k pending).
  scan_needed <- TRUE
  while (remaining()) {
    if (scan_needed) {
    scan_needed <- FALSE
    while (first_pending <= n_total &&
           tasks[[task_order[[first_pending]]]]$state != "pending")
      first_pending <- first_pending + 1L
    for (k in task_order[seq.int(first_pending,
                                 length.out = max(0L, n_total - first_pending + 1L))]) {
      t <- tasks[[k]]
      if (t$state != "pending") next
      slot <- t$pool
      if (t$pool == "read") {
        if (n_slot[["read"]] >= cap_read) next
        if (!read_ok(t)) next
        # Fused reads carry a kernel working set: ride the compute
        # byte budget too, or a cold fleet ramps N XLA working sets
        # at once regardless of what else holds the machine.
        if (t$mb > 0 && !comp_ok(t)) next
      } else {
        if (!comp_ok(t)) next
        # Compute tasks pin their OUTPUT region from launch, and
        # fetch-backed assembles pin read-store bytes like any read:
        # gate both by the store budget, with the comp-pool escape so
        # a saturated store still drains (see store_ok_comp).
        if (t$store_mb > 0 && !store_ok_comp(t)) next
        if (n_slot[["comp"]] >= cap_comp) next
        cprof <- pick_comp_prof(t)
        if (is.null(cprof)) next  # every eligible profile busy/at depth
        slot <- "comp"
      }
      if (!is_ready(k)) next
      prof <- if (slot == "read") read_prof else cprof
      inflight[[k]] <- if (is.null(t$ck)) t$launch(prof) else {
        # Compute-pool launches of warmed kernels ship the cache key
        # only when the CHOSEN profile provably holds the kernel; a
        # cold profile gets the closure and compiles on first use.
        warm_now <- slot == "comp" &&
          isTRUE(prof_warm[[.pw_key(prof, t$ck)]])
        t$launch(prof, with_fn = !warm_now)
      }
      tasks[[k]]$slot <- slot
      tasks[[k]]$prof <- prof
      if (slot == "comp") {
        prof_slots[[prof]] <- prof_slots[[prof]] + 1L
        if (!is.null(t$ck) && isTRUE(t$scan) &&
            !isTRUE(prof_warm[[.pw_key(prof, t$ck)]]))
          prof_cold_busy[[prof]] <- TRUE
      }
      n_slot[[slot]] <- n_slot[[slot]] + 1L
      n_inflight[[t$pool]] <- n_inflight[[t$pool]] + 1L
      tasks[[k]]$mb_live <- t$mb
      mb_inflight <- mb_inflight + tasks[[k]]$mb_live
      # Read-producing tasks pin their region from launch, not from
      # completion (fetch-backed assembles run on the compute pool but
      # pin store bytes just the same).
      mb_store_resident <- mb_store_resident + t$store_mb
      tasks[[k]]$state <- "running"
      log_line("launch", k, pool = t$pool,
               # routed profiles put the daemon identity in the slot
               # column: free per-daemon task attribution in
               # garry_task_report (the observability gap the deep
               # review deferred)
               slot = if (slot == "comp") prof else slot,
               mb = round(tasks[[k]]$mb_live, 1),
               store_mb = round(t$store_mb %||% 0, 1),
               ready = sprintf("%.3f", tasks[[k]]$t_ready %||% t_drain0))
    }
    }
    if (length(inflight) == 0L)
      .garry_error("scheduler deadlock: no runnable tasks",
                   "garry_scheduler_error")
    harvested <- FALSE
    for (k in names(inflight)) {
      h <- inflight[[k]]
      if (!mirai::unresolved(h)) {
        if (inherits(h$data, c("miraiError", "errorValue"))) {
          # A key-only launch found the daemon's jit cache cold
          # (warm-up failed there, or the cache was wiped): resend
          # once with the full stage closure.
          if (grepl("garry_jit_miss", as.character(h$data),
                    fixed = TRUE) && !isTRUE(tasks[[k]]$resent)) {
            tasks[[k]]$resent <- TRUE
            # The daemon's cache was cold: the warm-up failed there or
            # was evicted, so this kernel is NOT warm — clear the mark
            # or the resend (and every later task of the kernel)
            # bypasses the cold-kernel slow start and the scan-compile
            # surcharge exactly when memory is tightest (defect hunt
            # M2, 2026-07-30).
            if (!is.null(tasks[[k]]$ck))
              prof_warm[[.pw_key(tasks[[k]]$prof, tasks[[k]]$ck)]] <- FALSE
            # resend to the SAME profile: the miss identifies the one
            # daemon whose cache is cold, and with routed profiles the
            # closure must land exactly there
            inflight[[k]] <- tasks[[k]]$launch(tasks[[k]]$prof,
                                               with_fn = TRUE)
            next
          }
          cli::cli_abort(
            "task {k} failed on daemon: {as.character(h$data)}",
            class = c("garry_task_error", "garry_error"),
            task = k, stage = task_stage_of[[k]],
            pool = tasks[[k]]$pool)
        }
        chunk_vals[[k]] <- h$data
        tasks[[k]]$state <- "done"
        n_done <- n_done + 1L
        for (k2 in dependents[[k]]) {
          dep_left[[k2]] <- dep_left[[k2]] - 1L
          if (dep_left[[k2]] == 0L)
            tasks[[k2]]$t_ready <- unclass(Sys.time())
        }
        inflight[[k]] <- NULL
        pool_k <- tasks[[k]]$pool
        n_inflight[[pool_k]] <- n_inflight[[pool_k]] - 1L
        n_slot[[tasks[[k]]$slot]] <- n_slot[[tasks[[k]]$slot]] - 1L
        if (identical(tasks[[k]]$slot, "comp")) {
          pk <- tasks[[k]]$prof
          prof_slots[[pk]] <- prof_slots[[pk]] - 1L
          if (!is.null(tasks[[k]]$ck)) {
            # completion proves the kernel lives on this profile: exact
            # warmth for later key-only launches, and the profile's
            # cold-compile slot frees
            prof_warm[[.pw_key(pk, tasks[[k]]$ck)]] <- TRUE
            if (isTRUE(tasks[[k]]$scan)) prof_cold_busy[[pk]] <- FALSE
          }
        }
        mb_inflight <- mb_inflight - (tasks[[k]]$mb_live %||% tasks[[k]]$mb)
        harvested <- TRUE
        log_line("done", k)
        if (stream_write && !is.null(sink_task_j[[k]])) {
          for (j in sink_task_j[[k]]) {
            if (writer_on) {
              dispatch_write(sink@id, j, path, sink_it, sink_skey,
                             sink_spad, wspec$dtype %||% sink@grid@dtype)
            } else {
              ch <- chunk_of(sink@id, j)[[sink_skey]]
              .exec_check_writable(ch, nrow(sink_it))
              .exec_write_chunk(sink_ds, sink_it$x_off[j], sink_it$y_off[j],
                                ch, sink_spad,
                                wspec$dtype %||% sink@grid@dtype, wnodata,
                                scale = wspec$scale %||% numeric(0),
                                offset = wspec$offset %||% numeric(0))
            }
          }
          log_line("write", k)
        }
        for (sp in stream_sinks) {
          if (is.null(sp$task_j[[k]])) next
          for (j in sp$task_j[[k]]) {
            if (writer_on) {
              dispatch_write(sp$sid, j, sp$path, sp$it, sp$key,
                             sp$pad, sp$dtype)
            } else {
              ch <- chunk_of(sp$sid, j)[[sp$key]]
              .exec_check_writable(ch, nrow(sp$it))
              .exec_write_chunk(sp$ds, sp$it$x_off[j], sp$it$y_off[j],
                                ch, sp$pad, sp$dtype, wnodata,
                                scale = wspec$scale %||% numeric(0),
                                offset = wspec$offset %||% numeric(0))
            }
          }
          log_line("write", k)
        }
        release_store(k)
        # Eager fetch-cache cleanup: a fetch-backed source stage's
        # window files unlink once its last read (assemble) task is
        # done — bounds the tmpfs cache to slices still assembling.
        if (startsWith(k, "s")) {
          sk <- sub("^s(\\d+)_.*$", "\\1", k)
          left <- fetch_reads_left[[sk]]
          if (!is.null(left)) {
            fetch_reads_left[[sk]] <- left - 1L
            if (left <= 1L) {
              unlink(fetch_files_of[[sk]])
              rm(list = sk, envir = fetch_files_of)
            }
          }
        }
      }
    }
    if (writer_on && length(wr_inflight) > 0L && harvest_writes())
      harvested <- TRUE
    if (harvested) {
      flush_drops()
      scan_needed <- TRUE
      # Re-read MemAvailable on a clock: the caller's own session can
      # grow while we drain (host-side fits, assembled sinks), and the
      # gates must follow the machine rather than the configuration.
      if (difftime(Sys.time(), mem_last_check, units = "secs") >= 5) {
        refresh_mem_budgets()
        mem_last_check <- Sys.time()
        # Sample measurement vs model on the same clock: per-daemon
        # anon RSS and the modelled in-flight/resident bytes. This is
        # the diverging-lines plot every memory postmortem rebuilt by
        # hand (crop=0 flood, scan-compile OOM).
        if (!is.null(task_log)) {
          for (p in .garry_state$pool_pids) {
            a <- .garry_anon_mb_of(p)
            if (is.finite(a)) log_line("rss", as.character(p),
                                       mb = round(a, 1))
          }
          log_line("model", "-", mb = round(mb_inflight, 1),
                   store_mb = round(mb_store_resident, 1))
        }
      }
    }
    if (progress &&
        difftime(Sys.time(), last_report, units = "secs") > 5) {
      n_inf <- length(inflight)
      cli::cli_inform("garry: {n_done}/{n_total} tasks done, {n_inf} in flight")
      last_report <- Sys.time()
    }
    if (!harvested) Sys.sleep(0.002)
  }

  # Host-side: combines, then sink retrieval (mirrors execute_plan).
  # Sink/combine stages are never split-read sources (splits only exist
  # under a compute consumer), so chunk-keyed lookup always resolves.
  flush_drops(force = TRUE)
  log_line("drain_end", "-")
  on.exit(log_line("host_end", "-"), add = TRUE)
  # Outstanding writer-daemon writes must land before outputs close or
  # host-side retrieval begins; then the writer releases its handles.
  if (writer_on) {
    while (length(wr_inflight) > 0L) {
      if (!harvest_writes()) Sys.sleep(0.002) else flush_drops()
    }
    wcl <- mirai::everywhere(garry::.daemon_write_close(),
                             .compute = "garry_write")
    invisible(lapply(wcl, function(m) m[]))
    flush_drops(force = TRUE)
  }
  read_chunk <- chunk_of   # fused-aware (see chunk_of above)
  out_of <- function(s) {
    it <- chunk_iter(s@chunks)
    lapply(seq_len(nrow(it)), function(j) read_chunk(s@id, j))
  }

  # Streaming write already put every sink chunk on disk as it landed.
  if (stream_write) {
    if (!is.null(sink_ds)) {
      sink_ds$close()
      sink_ds <- NULL
    }
    return(invisible(path))
  }

  combine_vals <- new.env(parent = emptyenv())
  for (s in plan@stages) {
    if (s@kind != "reduce_combine") next
    part <- plan@stages[[s@inputs[[1L]]]]
    key <- .key(s@members[[1L]])
    # Combine closures run host-side on R arrays.
    partials <- lapply(lapply(out_of(part), `[[`, key), .sv_materialise)
    combine_vals[[.key(s@id)]] <- s@fn(partials)
  }

  # Sink assembly/write is the SHARED tail (.exec_sink_tail,
  # executor.R): the scheduler contributes its fused-aware chunk
  # lookup and the streamed-sink short-circuit; the shape of the tail
  # itself is one implementation for both executors.
  chunks_of <- function(st) {
    if (st@kind == "reduce_combine") list(combine_vals[[.key(st@id)]])
    else out_of(st)
  }
  streamed_path <- function(nm) {
    sp <- stream_sinks[[nm]]
    if (is.null(sp)) return(NULL)
    if (!is.null(sp$ds)) {
      sp$ds$close()
      stream_sinks[[nm]]$ds <<- NULL
    }
    sp$path
  }
  .exec_sink_tail(plan, graph, chunks_of = chunks_of, path = path,
                  wspec = wspec,
                  nodata = nodata, band_names = band_names,
                  streamed_path = streamed_path)
}
