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
# Inter-stage store: mori POSIX shared memory: daemons pin the regions
# they create for a run and the host refcounts them per consuming task
# No mid-graph halo store is needed (D11):
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
# morphology benchmark's compile storm): and identical kernels
# persist across runs. Node ids are normalized to stage-local
# indices (inputs in stored order, then members ascending); member
# fns compare by .fn_identity (formals, body expression, captured
# bindings), so captured free variables participate in the identity
# while closure call state and bytecode do not. The only per-stage residue
# is export NAMES (node ids baked into the composed closure), which
# the task bodies overwrite positionally via `out_keys`: exports
# are sorted ascending in every composed fn, so position is
# meaning.
.stage_kernel_sig <- function(graph, s) {
  .kernel_sig(
    graph,
    s@input_nodes,
    s@members,
    s@exports,
    s@kind,
    s@halo,
    s@out_pad,
    s@strip_rows
  )
}

# The signature of a composed kernel, stage or not (the gdal-direct
# routes compose their upper IR without one).
.kernel_sig <- function(
  graph,
  input_nodes,
  members,
  exports,
  kind = "compute",
  halo = 0L,
  out_pad = 0L,
  strip_rows = 0L
) {
  ids <- c(input_nodes, members)
  local <- stats::setNames(seq_along(ids), as.character(ids))
  parts <- lapply(members, function(id) {
    n <- graph_get(graph, id)
    base <- list(
      cls = class(n)[[1L]],
      parents = unname(local[as.character(n@parents)]),
      dtype = n@grid@dtype,
      pdims = names(graph_get(graph, n@parents[[1L]])@grid@dims)
    )
    if (S7::S7_inherits(n, MapNode)) {
      base$fn <- .fn_identity(n@fn)
    }
    if (S7::S7_inherits(n, FocalNode)) {
      base$fn <- .fn_identity(n@fn)
      base$radius <- n@radius
      base$weights <- n@weights
    }
    if (S7::S7_inherits(n, ReduceNode)) {
      base$op <- n@op
      base$over <- n@over
      base$nan_rm <- n@nan_rm
      # A custom reducer's identity lives in its fn, not `op`; omitting
      # it would alias distinct kernels in the jit cache.
      if (length(n@fn)) base$fn <- .fn_identity(n@fn[[1L]])
    }
    if (S7::S7_inherits(n, ScanNode)) {
      base$over <- n@over
      base$direction <- n@direction
      base$out_dtype <- n@dtype
      base$fn <- .fn_identity(n@fn[[1L]])
      # a third formal reads the axis labels (.compose: ScanNode)
      if (length(formals(n@fn[[1L]])) >= 3L) {
        base$labels <- n@grid@labels[[n@over]]
      }
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
  sig <- list(
    kind = kind,
    halo = halo,
    out_pad = out_pad,
    parts = parts,
    n_inputs = length(input_nodes),
    exports = unname(local[as.character(exports)]),
    strip_rows = strip_rows
  )
  paste0("k", rlang::hash(sig))
}


# Store-resident bytes (MB) one region pins: core window clipped to the
# grid, padded by `pad` per side, times the outer-dim plane count, at
# the region's true element size. Shared by read windows (pad = halo),
# fused outputs (pad = out_pad, nb = the EXPORT's planes -- pricing a
# fused region from its source window over-charged a fused multi-band
# read by the band count and would serialise the fleet) and compute
# outputs. `bytes` comes from .store_bytes_of: 4 only for raw f32; f64
# is 8.
.store_region_mb <- function(chunk_dim, grid_dims, pad, nb, bytes) {
  prod(
    pmin(as.numeric(chunk_dim), as.numeric(grid_dims[c("x", "y")])) + 2 * pad
  ) *
    max(1, nb) *
    bytes /
    2^20
}

# Launch a scheduler task's daemon call. With `timed`, the call runs
# inside an envelope that records when the DAEMON started it, so the
# task log can split queue time (a width-1 profile holds up to two
# tasks; the second waits behind the first) from run time. Launch-to-
# done alone conflates them: the SI tail's busy scan daemons read ~2x
# slower per task than they were (2026-10-23). `.expr` is the call as a
# language object; `...` are its data, as for mirai::mirai(). The
# formals are dotted so no data name partially matches them (`ex = ex`
# once bound to an `expr` formal).
.task_mirai <- function(.expr, ..., .compute, .timed = FALSE) {
  if (.timed) {
    .expr <- bquote({
      .garry_t0 <- Sys.time()
      .garry_v <- .(.expr)
      structure(
        list(
          v = .garry_v,
          t0 = unclass(.garry_t0),
          t1 = unclass(Sys.time()),
          retries = asNamespace("garry")$.daemon_retries_take()
        ),
        class = "garry_timed"
      )
    })
  }
  mirai::mirai(.expr, ..., .compute = .compute)
}

# A timed task's rows, from the daemon's own clock: when it started and
# ended, and any read retries, which a daemon has no other way to report
# (its warnings go nowhere), so a drain that survives on them shows.
.task_log_timed <- function(log_line, key, res) {
  log_line("start", key, time = .POSIXct(res$t0))
  log_line("end", key, time = .POSIXct(res$t1))
  if (res$retries > 0L) {
    log_line("retry", key, mb = res$retries, time = .POSIXct(res$t1))
  }
  invisible(NULL)
}

# A task's value once landed, with its rows when it ran timed. An error
# value passes through to the caller's own failure policy.
.task_landed <- function(log_line, key, res) {
  if (!inherits(res, "garry_timed")) {
    return(res)
  }
  .task_log_timed(log_line, key, res)
  log_line("done", key)
  res$v
}

# Launch a task outside the scheduler's ready queue with its launch row,
# ready as it launches. `.key` is only evaluated with a log, and the
# formals are dotted for .task_mirai()'s reason.
.task_launch <- function(
  .tl,
  .key,
  .expr,
  ...,
  .compute,
  .pool,
  .slot = .pool,
  .mb = 0
) {
  if (.tl$timed) {
    # taken before the launch row's own time, which line() reads first
    ready <- formatC(unclass(Sys.time()), format = "f", digits = 3)
    .tl$line(
      "launch",
      .key,
      pool = .pool,
      slot = .slot,
      mb = round(.mb, 1),
      ready = ready
    )
  }
  .task_mirai(.expr, ..., .compute = .compute, .timed = .tl$timed)
}

# Open a run's task log: `line` writes rows (runs share a log file, so
# each is marked), `timed` is what its launches pass on, and `tick()`
# samples memory on the scheduler's 5 s clock. `pools` are widths by pool
# name. `run` and `pools` are only evaluated with a log set: without one
# every part is a no-op.
.task_log_open <- function(run, pools) {
  task_log <- garry_opt("task_log")
  line <- .task_log_writer(task_log)
  if (is.null(task_log)) {
    return(list(line = line, timed = FALSE, tick = function() NULL))
  }
  line("run_start", run)
  for (nm in names(pools)) {
    line("pool", nm, mb = pools[[nm]])
  }
  last <- Sys.time()
  tick <- function() {
    if (difftime(Sys.time(), last, units = "secs") >= 5) {
      .task_log_memory(line)
      last <<- Sys.time()
    }
  }
  list(line = line, timed = TRUE, tick = tick)
}

# One memory sample for the task log, every row at `time` (the report
# sums a sweep's rows): each daemon's anon RSS (key = pid, pool = its
# role), the calling process's, the binding cgroup's usage against its
# limit, and /dev/shm in use.
.task_log_memory <- function(log_line, time = Sys.time()) {
  roles <- .garry_state$pid_role %||% character(0)
  for (p in .garry_state$pool_pids) {
    a <- .garry_anon_mb_of(p)
    if (is.finite(a)) {
      r <- unname(roles[as.character(p)])
      log_line(
        "rss",
        as.character(p),
        pool = if (is.na(r)) "" else r,
        mb = round(a, 1),
        time = time
      )
    }
  }
  h <- .garry_anon_mb_of(Sys.getpid())
  if (is.finite(h)) {
    log_line("host", Sys.getpid(), mb = round(h, 1), time = time)
  }
  cg <- .garry_cgroup_mem()
  if (!is.null(cg)) {
    log_line(
      "cgroup",
      "-",
      mb = round(cg$current, 1),
      store_mb = round(cg$limit, 1),
      time = time
    )
  }
  shm <- .garry_shm_used_mb()
  if (is.finite(shm)) {
    log_line("shm", "-", mb = round(shm, 1), time = time)
  }
  invisible(NULL)
}

# The line writer for the task log at `task_log` (a no-op without one),
# shared by every distributed route. Task-log schema (locked;
# garry_task_report() is the reader):
#   time,event,key,pool,slot,mb,store_mb,ready
# launch rows carry pool/slot, the admission-priced working set and
# store bytes, and the READY timestamp (deps satisfied) so queue-wait
# separates from run time; rss rows sample one daemon's anon MB
# (key = pid); model rows sample the modelled in-flight/resident MB;
# pool rows give a run's pool widths (key = pool, mb = daemons); retry
# rows count a task's read retries (mb = retries); resend rows mark a
# kernel sent again to a daemon that lacked it; warm_fail rows a failed
# warm-up (key = its task, pool = profile). Task keys name their stage
# before the underscore: s<stage> reads and kernels, f<index> fetches,
# w<stage> writes, warm<stage> warm-ups, and on the gdal-direct routes
# f<source>, m<source> the mask, b<source> a band and warm0 its warm-up.
.task_log_writer <- function(task_log) {
  if (is.null(task_log)) {
    return(function(...) NULL)
  }
  if (!file.exists(task_log) || file.size(task_log) == 0) {
    cat(
      "time,event,key,pool,slot,mb,store_mb,ready\n",
      file = task_log,
      append = TRUE
    )
  }
  function(
    event,
    key,
    pool = "",
    slot = "",
    mb = "",
    store_mb = "",
    ready = "",
    time = Sys.time()
  ) {
    stamp <- formatC(unclass(time), format = "f", digits = 3)
    cat(
      paste(stamp, event, key, pool, slot, mb, store_mb, ready, sep = ","),
      "\n",
      sep = "",
      file = task_log,
      append = TRUE
    )
  }
}

# May a compute-pool task pinning `store_mb` launch with the store at
# `resident` of its `budget` MB, `n_inflight` compute-pool tasks in
# flight on `n_comp` daemons? Over budget, a kernel task (one that
# retires the regions filling the store) may run one per daemon and a
# fetch-backed assemble (which adds a region) only alone. See
# store_ok_comp in execute_plan_mirai().
.store_gate_comp <- function(
  resident,
  store_mb,
  budget,
  n_inflight,
  n_comp,
  kernel
) {
  if (resident + store_mb <= budget) {
    return(TRUE)
  }
  if (kernel) n_inflight < max(1L, n_comp) else n_inflight == 0L
}

# The store budget the machine allows now, for a run with `resident_mb`
# in a store of `cfg` configured MB and `floor_mb` a region. The RAM pool
# is `mem_frac` of what is available; reads are cheap to hold and
# expensive to redo, so they get at most a third of it (`ram_read`).
# /dev/shm is the ground truth: the resident-byte accounting is an
# estimate decremented at queue-drop time, so physical high-water can
# run ahead of it within a flush window, and other tmpfs consumers (the
# fetch cache, other processes) share the mount. So `read` also fits
# resident + admissible in what /dev/shm has free, and `tight` says free
# space has breached the headroom and queued drops must go now. tmpfs
# pages charge the creating process's CGROUP (a systemd-run scope counts
# them against MemoryMax while host df still shows free space), so free
# space is the MINIMUM of the mount and the cgroup headroom: without the
# cgroup term the backstop never fires inside a confined run and the
# scope thrashes at its ceiling. NULL when RAM cannot be read
# (.garry_ram_avail_mb() warns), which leaves the budgets open.
.shm_headroom_mb <- 512
.store_budget <- function(cfg, floor_mb, resident_mb, mem_frac) {
  avail <- .garry_ram_avail_mb()
  if (is.na(avail)) {
    return(NULL)
  }
  pool <- avail * mem_frac
  ram_read <- max(floor_mb, min(cfg, pool / 3))
  free <- c(.garry_shm_free_mb(), .garry_cgroup_avail_mb())
  free <- free[!is.na(free)]
  read <- ram_read
  tight <- FALSE
  if (length(free)) {
    free <- min(free)
    read <- min(ram_read, max(floor_mb, resident_mb + free - .shm_headroom_mb))
    tight <- free < .shm_headroom_mb
  }
  list(avail = avail, pool = pool, ram_read = ram_read, read = read, tight = tight)
}

# Element bytes a stored region of `dtype` costs: f32 payloads hold 4 B,
# and everything else 8 B, f64 and the R doubles of a non-float value.
.store_bytes_of <- function(dtype) {
  if (identical(dtype, "f32")) 4 else 8
}

# Outer-dim plane count of a node's grid (bands, time slices).
.node_outer_nb <- function(graph, nid) {
  .grid_planes(.node_grid(graph_get(graph, nid)))
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
execute_plan_mirai <- function(
  plan,
  path = NULL,
  nodata = NULL,
  band_names = NULL,
  wspec = NULL
) {
  .garry_opt_check()
  # Distributed execution runs on the garry_daemons() split pools: read/warp
  # tasks route to the read pool: where anvl/PJRT never loads, so a reader
  # stays at ~60 MB: and compute tasks to a small pool of fat daemons,
  # confining per-chunk working sets to few processes.
  if (!garry_daemons_set()) {
    .garry_error(
      paste0(
        "no garry daemon pools are running; call garry_daemons() first"
      ),
      "garry_scheduler_error"
    )
  }
  read_prof <- "garry_read"
  comp_profs <- .comp_profiles()
  profiles <- unique(c(read_prof, comp_profs))
  .assert_pools_alive(profiles)
  n_read <- .gd_n_compute(read_prof)
  n_comp <- .comp_n()
  # Per-profile launch slots (width-1 profiles, .daemon_depth each) and
  # EXACT per-profile kernel warmth: key-only launches go only to a
  # profile that provably holds the kernel. Scan tasks are CONFINED to
  # `scan_profs` (set once the plan is known), at most one cold compile
  # in flight per profile: a structural bound, as workstream B measured
  # anonymous rotation growing EVERY daemon to the scan working set.
  prof_slots <- new.env(parent = emptyenv())
  for (p in comp_profs) {
    prof_slots[[p]] <- 0L
  }
  # Compiled programs outlive a run on their daemon, and a run's warm-up
  # need not send them again. Closures keep per-run warmth, as they are
  # discarded on arrival anyway.
  wire_program <- .kernel_wire_program() &&
    all(vapply(plan@stages, function(s) identical(s@device, "cpu"), logical(1)))
  # macOS daemons empty their caches at run start (.daemon_jit_reset)
  keep_warm <- wire_program && .kernels_outlive_runs()
  if (keep_warm && is.null(.garry_state$prof_warm)) {
    .garry_state$prof_warm <- new.env(parent = emptyenv())
  }
  prof_warm <- if (keep_warm) {
    .garry_state$prof_warm
  } else {
    new.env(parent = emptyenv()) # "prof\x1fck" -> TRUE
  }
  prof_cold_busy <- new.env(parent = emptyenv()) # prof -> TRUE while compiling
  scan_profs <- character(0) # set once the plan is known
  .pw_key <- function(p, ck) paste0(p, "\x1f", ck)
  pick_comp_prof <- function(t) {
    is_cold <- !is.null(t$ck) && isTRUE(t$scan)
    cands <- if (is_cold && length(scan_profs)) {
      scan_profs
    } else if (
      length(scan_profs) &&
        length(comp_profs) > length(scan_profs) &&
        !is_cold
    ) {
      # ordinary kernels prefer the non-scan profiles (keeps
      # them lean); scan profiles remain a fallback
      c(setdiff(comp_profs, scan_profs), scan_profs)
    } else {
      comp_profs
    }
    if (is_cold) {
      # a warm profile first (exact key-only launch), least-loaded
      best <- NULL
      bn <- .daemon_depth
      for (p in cands) {
        v <- prof_slots[[p]]
        if (v < bn && isTRUE(prof_warm[[.pw_key(p, t$ck)]])) {
          bn <- v
          best <- p
        }
      }
      if (!is.null(best)) {
        return(best)
      }
      # else a designated profile not currently compiling
      for (p in cands) {
        if (
          prof_slots[[p]] < .daemon_depth &&
            !isTRUE(prof_cold_busy[[p]])
        ) {
          return(p)
        }
      }
      return(NULL)
    }
    best <- NULL
    bn <- .daemon_depth
    for (p in cands) {
      v <- prof_slots[[p]]
      if (v < bn) {
        bn <- v
        best <- p
      }
    }
    best
  }
  # The writer matters only to a run that writes, which checks it below.
  live <- c(profiles, if (.gd_n_compute("garry_write") > 0L) "garry_write")
  .garry_abi_check(live)
  # Back-pressure: reads throttle on slots + resident-store bytes;
  # compute launches are gated by a BYTE budget (below): per-task
  # resident estimates against the live RAM pool: so many small
  # chunks (per-slice mask cleanup, ~10 MB each) flow at full pool
  # width while big fused medians (~350 MB each) self-limit.
  cap_read <- max(.daemon_depth * n_read, 4L)
  # In-flight compute is bounded by the RAM pool (refresh_mem_budgets,
  # below) and each profile's depth, not a per-daemon byte figure:
  # ram_budget_mb is the per-CHUNK size target of the chunking pass.
  comp_budget_mb <- Inf
  mb_inflight <- 0
  n_mb_inflight <- 0L # byte-accounted tasks in that sum
  read_budget_mb <- garry_opt("read_budget_mb")
  # Largest co-resident read SET (one window per input of the widest
  # compute stage): filled during task build; the effective read budget
  # is floored above it so a wide stage's full input set can always be
  # resident at once: a budget below one set cannot deadlock (the
  # no-read-in-flight escape hatch still trickles), but it serialises
  # every read of the set, which is a crawl, not back-pressure.
  max_set_mb <- 0

  .daemons_run_start(live, trim = TRUE)

  graph <- plan@graph
  run_id <- .garry_run_id()
  # Producer-side write quantization (g_quantize, the one quantizer;
  # collect.R routes quantizing plans off the cd/gd fast paths).
  # `wq_keys_of[[stage key]]` lists the stage's sink exports CLEARED
  # for producer quantization: sink nodes no other stage consumes (a
  # store value another stage still reads must stay f32). Uncleared
  # or unfused sinks are not streamed; they fall to the host tail,
  # where .exec_write_sink applies the same device quantizer. Built
  # BEFORE the task loop: fused read tasks bind fuse$wq at build time.
  wq <- .exec_wq(wspec, nodata)
  wq_keys_of <- list()
  sink <- plan@stages[[plan@sink]]
  sink_nids <- if (length(plan@sinks) > 0L) {
    plan@sinks
  } else {
    sink@members[[length(sink@members)]]
  }
  if (!is.null(wq)) {
    consumed <- unique(unlist(lapply(plan@stages, function(s2) {
      vapply(s2@input_nodes, .key, character(1))
    })))
    for (nid in unique(sink_nids)) {
      if (.key(nid) %in% consumed) {
        next
      }
      st <- .stage_of_node(plan, nid)
      k <- .key(st@id)
      wq_keys_of[[k]] <- unique(c(wq_keys_of[[k]], .key(nid)))
    }
  }
  # Streaming requires the writer to receive READY bytes: with wq
  # active, only cleared compute/reduce_partial sinks (quantized in
  # .daemon_run_compute_shm) and fused sinks (quantized in
  # .apply_fuse) may stream.
  .wq_stream_ok <- function(st, nid) {
    is.null(wq) ||
      (.key(nid) %in% wq_keys_of[[.key(st@id)]] &&
        st@kind %in% c("compute", "reduce_partial"))
  }
  # Inter-stage store is POSIX shared memory (mori): daemons pin every
  # region they created for this run and release them once the host is done
  # (regions outlive tasks, not the run); host-side handles die with
  # `chunk_vals`. Both pools pin regions (readers: windows; computers:
  # results).
  on.exit(
    for (p in profiles) {
      try(
        mirai::everywhere(asNamespace("garry")$.daemon_shm_clear(), .compute = p),
        silent = TRUE
      )
    },
    add = TRUE
  )
  chunk_vals <- new.env(parent = emptyenv()) # task key -> shared value

  # ---- fetch/assemble split (phase 12) --------------------------------
  # GTI source stages over remote locations split into per-item-asset
  # window FETCH tasks (plain gdal_translate -srcwin to tmpfs: many
  # tiny blocking reads keep the link saturated where few big warped
  # reads idle at ~25% duty cycle) plus the ordinary read task
  # ASSEMBLING the mosaic from a location-rewritten local index at
  # local speed. Requires the index sidecar gti_index_create() writes
  # and garry's own "slice = '...'" FILTER form; anything else falls
  # back to direct remote reads.
  fetch_mode <- garry_opt("fetch")
  fetch_root <- NULL
  fetch_state <- new.env(parent = emptyenv()) # orig index -> local info
  fetch_n_idx <- 0L
  fetch_made <- new.env(parent = emptyenv()) # fetch task key -> TRUE
  fetch_files_of <- new.env(parent = emptyenv()) # sid -> files to unlink
  # fetched files are shared by every stage that reads the same index
  # slice: count the stages still holding each one, unlink at zero
  fetch_holders <- new.env(parent = emptyenv()) # file -> stage count
  fetch_reads_left <- new.env(parent = emptyenv()) # sid -> open read tasks
  on.exit(
    if (!is.null(fetch_root)) {
      unlink(fetch_root, recursive = TRUE)
    },
    add = TRUE
  )

  prepare_fetch <- function(rpath, roo, grid) {
    ix <- .fetch_index(rpath, fetch_mode)
    if (is.null(ix)) {
      return(NULL)
    }
    ipath <- sub("^GTI:", "", rpath)
    st <- fetch_state[[ipath]]
    if (is.null(st)) {
      meta <- ix$meta
      ent <- meta$entries
      do_fetch <- ix$fetch
      if (is.null(fetch_root)) {
        base <- if (dir.exists("/dev/shm")) "/dev/shm" else tempdir()
        fetch_root <<- file.path(base, .glue("garry-fetch-{run_id}"))
        dir.create(fetch_root)
      }
      fetch_n_idx <<- fetch_n_idx + 1L
      sub <- file.path(fetch_root, .glue("i{fetch_n_idx}"))
      dir.create(sub)
      dst <- file.path(
        sub,
        .glue(
          "r{formatC(seq_len(nrow(ent)), width = 4, flag = '0')}.tif"
        )
      )
      lent <- ent
      lent$location <- ifelse(do_fetch, dst, ent$location)
      lpath <- file.path(sub, basename(ipath))
      gti_index_create(
        lent,
        lpath,
        crs = meta$crs,
        layer = meta$layer %||% "index"
      )
      st <- list(
        id = fetch_n_idx,
        local = paste0("GTI:", lpath),
        src = ent$location,
        dst = dst,
        do = do_fetch,
        slice = ent$slice
      )
      fetch_state[[ipath]] <- st
    }
    slval <- .gti_slice_of(roo)
    if (is.null(slval) || is.na(slval)) {
      return(NULL) # no slice filter, or one only GDAL can evaluate
    }
    rows <- which(st$slice == slval & st$do)
    keys <- .glue("f{st$id}_{rows}")
    for (k in seq_along(rows)) {
      key <- keys[[k]]
      if (!is.null(fetch_made[[key]])) {
        next
      }
      fetch_made[[key]] <- TRUE
      local({
        src <- st$src[[rows[[k]]]]
        dst <- st$dst[[rows[[k]]]]
        ex <- grid@extent
        cr <- grid@crs
        tr <- grid@transform[[2L]] # target x resolution: decimate coarse fetches
        add_task(key, character(0), "read", prio = 1L, launch = function(prof) {
          .task_mirai(
            quote(
              asNamespace("garry")$.daemon_fetch_window(
                src,
                dst,
                ex,
                cr,
                target_res = tr
              )
            ),
            # dispatch-time hook: a fetch launched deep into a long
            # drain re-signs a near-expiry MPC token (io R4)
            src = .mpc_resign(src),
            dst = dst,
            ex = ex,
            cr = cr,
            tr = tr,
            .compute = prof,
            .timed = tl$timed
          )
        })
      })
    }
    list(deps = keys, local = st$local, files = st$dst[rows])
  }

  sc <- .placement_scan(plan)
  consumers_of <- sc$consumers_of
  warp_only <- sc$warp_only
  # Node id -> producing stage id (first-wins, matching .exec_in_meta's
  # Find over creation order: a spatially-reduced root is a member of
  # both its partial and combine stages, and the PARTIAL produces it).
  node_stage <- integer(length(plan@graph@nodes))
  for (t2 in rev(plan@stages)) {
    node_stage[t2@members] <- t2@id
  }

  # Build the task table. Combine stages are host-side, handled at
  # drain. The table is an ENVIRONMENT: named-list `[[<-` inserts do a
  # linear name match plus spine copy each call: O(n^2) over the
  # build, minutes of host time at ~2e4 tasks before anything runs.
  # `seq` records insertion order (ls() on an env is alphabetical),
  # which the launch order below uses as its tie-break.
  tasks <- new.env(parent = emptyenv())
  n_task <- 0L
  add_task <- function(
    key,
    deps,
    pool,
    launch,
    mb = 0,
    prio = 2L,
    dev = "cpu",
    store_mb = 0,
    ck = NULL,
    scan = FALSE
  ) {
    n_task <<- n_task + 1L
    tasks[[key]] <- list(
      deps = deps,
      pool = pool,
      launch = launch,
      mb = mb,
      prio = prio,
      dev = dev,
      store_mb = store_mb,
      seq = n_task,
      ck = ck,
      scan = scan,
      state = "pending"
    )
  }
  # For coarse-reading (split) source stages: task key per compute chunk,
  # and (mori store) each compute chunk's element name in the shared
  # parts list.
  source_deps <- new.env(parent = emptyenv())
  source_elts <- new.env(parent = emptyenv())
  # Mori store lifecycle: EVERY store region (read window or compute
  # output) is refcounted per consuming TASK and dropped the moment its
  # last consumer retires: except regions the host still needs after
  # the drain (combine partials, non-streamed sink chunks; see
  # host_keep below). Without this the store only empties at
  # end-of-run: streamed sink chunks stay pinned after they are on
  # disk and every intermediate stage's full output survives the whole
  # execution: a multi-stage tail over a 22-band cube accumulates
  # gigabytes of dead regions and OOMs where its live frontier is
  # small.
  task_ins <- new.env(parent = emptyenv()) # task -> store deps consumed
  store_users <- new.env(parent = emptyenv()) # task -> n consumers left
  task_stage_of <- new.env(parent = emptyenv()) # task -> store stage id
  stage_store_mb <- new.env(parent = emptyenv()) # read stage -> window MB

  # One read task: `rd` holds what its stage's tasks share, `parts` a
  # coarse read's per-compute-chunk windows. Forced, as the build loop
  # moves on before a launch closure runs.
  add_read_task <- function(key, core, rd, parts = NULL) {
    force(core)
    force(parts)
    force(rd)
    fs <- rd$fspec
    if (rd$grows) {
      fs$grow <- .chunk_grow(rd$cg, core)
    }
    if (isTRUE(fs$takes_ring)) {
      fs$ring <- .ring_cells(core, rd$cg@grid@dims, rd$cg@halo, fs$grow)
    }
    add_task(
      key,
      rd$deps,
      rd$pool,
      mb = rd$mb,
      store_mb = rd$store_mb,
      launch = function(prof) {
        .task_mirai(
          quote(asNamespace("garry")$.daemon_run_source_shm(
            ra,
            cg,
            core,
            k2,
            reg,
            parts = parts,
            fuse = fs,
            read_raw = rr
          )),
          ra = rd$ra,
          cg = rd$cg,
          core = core,
          k2 = rd$skey,
          reg = .glue("r{run_id}_{key}"),
          parts = parts,
          fs = fs,
          rr = rd$raw,
          .compute = prof,
          .timed = tl$timed
        )
      }
    )
    task_stage_of[[key]] <- rd$oid
  }

  # One compute task over chunk `j`, `core`; `cd` holds what its stage's
  # tasks share. Its input handles resolve at launch, when its
  # dependencies are done and `chunk_vals` holds each shared object (a
  # ~30-byte name on the wire). `with_fn = FALSE` sends the kernel's key
  # alone, for a daemon known to hold it: re-shipping a kernel costs MBs
  # of host serialization a task.
  add_comp_task <- function(j, core, cd) {
    force(core)
    force(cd)
    in_deps <- vapply(
      cd$meta,
      function(m) {
        dep <- source_deps[[.key(m$id)]]
        if (is.null(dep)) .glue("s{m$id}_c{j}") else dep[[j]]
      },
      character(1)
    )
    # coarse-read inputs address their part element
    shm_keys <- vapply(
      seq_along(cd$meta),
      function(i) {
        el <- source_elts[[.key(cd$meta[[i]]$id)]]
        if (is.null(el)) cd$in_keys[[i]] else el[[j]]
      },
      character(1)
    )
    edge <- if (length(cd$pads)) {
      list(pads = cd$pads, core = core, gdims = cd$grid_dims, dtypes = cd$out_dtypes)
    }
    grow <- if (cd$grows) .chunk_grow(cd$cg, core)
    ring <- if (cd$ring) .ring_cells(core, cd$grid_dims, cd$need, grow)
    key <- .glue("s{cd$id}_c{j}")
    rk <- unique(in_deps)
    add_task(
      key,
      rk,
      "comp",
      mb = cd$mb,
      store_mb = cd$store_mb,
      scan = cd$scan,
      dev = cd$device,
      ck = cd$ck,
      launch = function(prof, with_fn = TRUE) {
        .task_mirai(
          quote(asNamespace("garry")$.daemon_run_compute_shm(
            ck,
            fn,
            in_vals,
            in_keys,
            trims,
            dtypes,
            reg,
            out_keys = ok,
            device = dv,
            edge = eg,
            wq = wqt,
            grow = gr,
            ring = rg
          )),
          ck = cd$ck,
          fn = if (with_fn) cd$fn else NULL,
          in_vals = lapply(in_deps, function(d) chunk_vals[[d]]),
          in_keys = shm_keys,
          trims = cd$trims,
          dtypes = cd$dtypes,
          reg = .glue("r{run_id}_{key}"),
          ok = cd$out_keys,
          dv = cd$device,
          eg = edge,
          wqt = cd$wq,
          gr = grow,
          rg = ring,
          .compute = prof,
          .timed = tl$timed
        )
      }
    )
    # A region frees when the last task consuming it retires.
    task_ins[[key]] <- rk
    for (r2 in rk) {
      store_users[[r2]] <- (store_users[[r2]] %||% 0L) + 1L
    }
    task_stage_of[[key]] <- cd$id
  }

  # Compute-on-read (phase 12b, CPU only): a compute stage with ONE
  # input stage: a source read consumed by nobody else: and a
  # single export can execute inside the source's read tasks: the
  # kernel runs once per read window and only its OUTPUT is stored
  # and split. The per-chunk task fleet for source-fed kernel chains
  # (mask cleanup: 330 tasks on the benchmark) disappears, with its
  # dispatch, extract, upload and store round-trips. WHICH eligible
  # chains fuse is the placement pass's decision (R/placement.R),
  # returned as a side table the task build consumes.
  # Shape the compute pool for THIS plan before costing placement
  # against it (scan plans get fat masks, kernel fleets narrow ones).
  # Scan confinement: the first K = garry.scan_profiles profiles are
  # designated for scan tasks; pick_comp_prof routes them nowhere
  # else, so scan live/retained memory is K x working set by
  # construction (workstream B).
  has_scan <- function(s) .has_member(graph, s@members, ScanNode)
  scan_profs <- if (any(vapply(plan@stages, has_scan, logical(1)))) {
    comp_profs[seq_len(min(
      as.integer(garry_opt("scan_profiles")),
      length(comp_profs)
    ))]
  } else {
    character(0)
  }
  .comp_pool_shape(n_comp, length(scan_profs))
  placement <- .plan_placement(
    plan,
    consumers_of,
    warp_only,
    n_read = n_read,
    n_comp = n_comp,
    reader_threads = .garry_state$reader_threads,
    comp_threads = .garry_state$comp_threads,
    avail_mb = .garry_ram_avail_mb()
  )
  fuse_of <- placement$by_source # source sid -> fuse spec
  fused_cid <- placement$fused # fused compute sid -> TRUE

  # Jit warm-up specs, one per compute stage: the modal
  # (full) chunk shape, compiled on every compute daemon at run start.
  warm_specs <- list()

  # Task insertion follows the launch-order invariant: the ready-queue
  # scan below launches pending tasks in insertion order, so sibling
  # producer subtrees (e.g. per-band reads) enqueue contiguously and
  # each band's fused tail overlaps the next band's read drain.
  for (s in plan@stages[.stage_launch_order(plan)]) {
    if (s@kind == "reduce_combine") {
      next
    }
    if (s@kind == "source_read" && warp_only[[s@id]]) {
      next
    }
    if (!is.null(fused_cid[[.key(s@id)]])) {
      next
    } # runs on its read
    it <- chunk_iter(s@chunks)

    if (s@kind %in% c("source_read", "warp")) {
      ra <- .stage_read_args(graph, s)
      skey <- .key(s@members[[1L]])
      fspec <- fuse_of[[.key(s@id)]]
      oid <- s@id # store identity: fused stage id
      # A fused kernel runs at read granularity: edge read windows grow
      # to the modal window like edge compute chunks (.apply_fuse).
      fuse_grows <- !is.null(fspec) &&
        .stage_grows_edges(graph, plan@stages[[fspec$cid]])
      if (!is.null(fspec)) {
        oid <- fspec$cid
        skey <- fspec$out_key
        if (wire_program) {
          fspec <- .fuse_as_program(fspec, graph, s, fuse_grows)
        }
        # Fused SINK: quantize in .apply_fuse when this fused export is
        # a cleared sink (no other consumer reads the store value).
        if (
          !is.null(wq) &&
            fspec$out_key %in% wq_keys_of[[.key(fspec$cid)]]
        ) {
          fspec$wq <- wq[c("scale", "offset", "nodata", "dtype")]
        }
      }
      fetch_deps <- character(0)
      read_pool <- "read"
      # A FUSED read's kernel working set rides the in-flight compute
      # byte budget (see comp_ok): the placement pass estimated it.
      task_mb_read <- if (!is.null(fspec)) fspec$ws_mb else 0
      if (s@kind == "source_read") {
        fp <- prepare_fetch(ra$path, ra$open_options, s@grid)
        if (!is.null(fp)) {
          fetch_deps <- fp$deps
          ra$path <- fp$local
          fetch_files_of[[.key(s@id)]] <- fp$files
          for (ff in unique(fp$files)) {
            fetch_holders[[ff]] <- (fetch_holders[[ff]] %||% 0L) + 1L
          }
          # Fetch-backed assembles are local CPU (warp + any fused
          # kernel): route them to the compute pool, which idles
          # during the drain now that compute-on-read emptied it of
          # per-chunk mask tasks: band 1 assembles DURING band 2's
          # fetches and the read pool never stops downloading.
          read_pool <- "comp"
          task_mb_read <- max(
            task_mb_read,
            prod(pmin(
              as.numeric(s@chunks@chunk_dim),
              as.numeric(s@grid@dims[c("x", "y")])
            )) *
              24 /
              2^20
          )
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
        .store_region_mb(
          s@chunks@chunk_dim,
          s@grid@dims,
          s@chunks@halo,
          .node_outer_nb(graph, s@members[[1L]]),
          .store_bytes_of(
            graph_get(graph, s@members[[1L]])@grid@dtype
          )
        )
      } else {
        .store_region_mb(
          s@chunks@chunk_dim,
          s@grid@dims,
          fspec$out_pad,
          fspec$out_nb,
          .store_bytes_of(fspec$out_dtype)
        )
      }
      stage_store_mb[[.key(oid)]] <- store_mb_read
      rd <- list(
        ra = ra,
        cg = s@chunks,
        oid = oid,
        skey = skey,
        fspec = fspec,
        grows = fuse_grows,
        # Raw read gate (D21): halo-free windows whose consumers see f32
        # values, the node's own dtype for pure reads, the fused kernel's
        # input dtype for compute-on-read. Non-f32 dtypes keep the matrix
        # path (bitwise consumers, integer exactness).
        raw = s@chunks@halo == 0L &&
          identical(
            if (is.null(fspec)) {
              graph_get(graph, s@members[[1L]])@grid@dtype
            } else {
              fspec$dtype
            },
            "f32"
          ),
        deps = fetch_deps,
        pool = read_pool,
        mb = task_mb_read,
        store_mb = store_mb_read
      )
      if (length(fetch_deps)) {
        fetch_reads_left[[.key(s@id)]] <- nrow(it)
      }
      split_cg <- .exec_split_cg(plan, s, consumers_of[[s@id]])
      if (is.null(split_cg)) {
        if (!is.null(fspec)) {
          source_deps[[.key(oid)]] <- .glue("s{s@id}_c{seq_len(nrow(it))}")
        }
        for (j in seq_len(nrow(it))) {
          add_read_task(.glue("s{s@id}_c{j}"), it[j, ], rd)
        }
      } else {
        # Coarse reads: share the whole read buffer; consumers slice
        # their window zero-copy. Compute chunk j's dependency is the
        # READ task covering it.
        its <- chunk_iter(split_cg)
        # A fused kernel consumes the halo; its output carries the
        # fused stage's out_pad ring (D22), 0 in the common case.
        H2 <- 2L * (if (is.null(fspec)) split_cg@halo else fspec$out_pad)
        dep_of <- character(nrow(its))
        elt_of <- .glue("{skey}\x1f{seq_len(nrow(its))}")
        for (r in seq_len(nrow(it))) {
          members <- .exec_split_members(its, it[r, ])
          dep_of[members] <- .glue("s{s@id}_r{r}")
          # Parts carry the stage halo (see .exec_split_cg): same r0/c0,
          # slice grown by 2*halo.
          parts <- lapply(members, function(j) {
            list(
              r0 = its$y_off[[j]] - it$y_off[[r]],
              c0 = its$x_off[[j]] - it$x_off[[r]],
              nr = its$y_size[[j]] + H2,
              nc = its$x_size[[j]] + H2,
              elt = elt_of[[j]]
            )
          })
          add_read_task(.glue("s{s@id}_r{r}"), it[r, ], rd, parts)
        }
        source_deps[[.key(oid)]] <- dep_of
        source_elts[[.key(oid)]] <- elt_of
      }
    } else {
      # compute / reduce_partial
      in_meta <- .exec_in_meta(graph, s, plan@stages, node_stage)
      max_set_mb <- max(
        max_set_mb,
        sum(vapply(
          in_meta,
          function(m) {
            stage_store_mb[[.key(m$id)]] %||% 0
          },
          numeric(1)
        ))
      )
      sig <- paste0(.stage_kernel_sig(graph, s), "@", s@device)
      need <- s@halo + s@out_pad
      # clipped to the grid, as the store and warm-up estimates are: the
      # plan-wide chunk dim can exceed a small grid
      modal <- .modal_chunk(s@chunks)
      task_mb <- .stage_bytes_per_px(graph, s@members, s@input_nodes) *
        prod(as.numeric(modal) + 2 * need) /
        2^20
      # The /2 discount reflects mori's zero-copy shared INPUT mappings:
      # the per-px estimate is calibrated for private R-double inputs, but
      # under mori the inputs are shared and the resident cost is mostly
      # the f32 device copies (~half). It does NOT apply to a scan stage,
      # whose cost is dominated by the body's PRIVATE live f64 state cubes,
      # not its inputs -- halving those under-counted the robust Kalman
      # tail's working set and let the budget over-admit concurrent scan
      # chunks. The planner's chunk sizing keeps the full figure.
      scans <- has_scan(s)
      if (!scans) {
        task_mb <- task_mb / 2
      }
      # Edge chunks run the stage's modal kernel, warm from the
      # pre-drain compile, on inputs grown to the modal shape
      # (.sv_grow), instead of every daemon compiling a kernel for each
      # edge shape (a robust Kalman stage: ~2.5 s a shape).
      pad_edges <- .stage_grows_edges(graph, s)
      takes_ring <- .takes_ring(graph, s)
      stage_fn <- s@fn
      if (wire_program) {
        pg <- .stage_as_program(graph, s, sig, in_meta, need, pad_edges)
        stage_fn <- pg$set
        sig <- pg$key
      }
      dtypes <- vapply(in_meta, function(m) m$dtype, character(1))
      # Scan kernels pre-warm too: the broadcast is TARGETED at the
      # K designated scan profiles only (the validated <= 2 concurrent
      # pre-drain compiles, daemon-exact at any pool width).
      warm_specs[[length(warm_specs) + 1L]] <- list(
        ck = sig,
        stage = s@id,
        scan = scans,
        fn = stage_fn,
        device = s@device,
        dtypes = dtypes,
        # Outer-dim product per input: a coalesced multi-band source
        # (or a cross-stage cube intermediate) warms with the rank-3
        # shape the real chunks arrive in.
        outers = vapply(
          s@input_nodes,
          function(nid) as.integer(.node_outer_nb(graph, nid)),
          integer(1)
        ),
        nr = modal[[2L]] + 2L * need,
        nc = modal[[1L]] + 2L * need,
        ring = takes_ring
      )
      # Compute outputs pin store regions exactly like read windows:
      # from launch until the last consumer retires, or for host_keep
      # stages until end of run.
      epads <- if (length(s@export_pads)) {
        as.integer(s@export_pads)
      } else {
        integer(length(s@exports))
      }
      store_mb_comp <- sum(vapply(
        seq_along(s@exports),
        function(ei) {
          e <- s@exports[[ei]]
          .store_region_mb(
            s@chunks@chunk_dim,
            s@grid@dims,
            epads[[ei]],
            .node_outer_nb(graph, e),
            .store_bytes_of(graph_get(graph, e)@grid@dtype)
          )
        },
        numeric(1)
      ))
      stage_store_mb[[.key(s@id)]] <- store_mb_comp
      okeys <- vapply(s@exports, .key, character(1))
      names(epads) <- okeys
      cd <- list(
        id = s@id,
        cg = s@chunks,
        grid_dims = s@grid@dims,
        fn = stage_fn,
        ck = sig,
        device = s@device,
        meta = in_meta,
        in_keys = vapply(s@input_nodes, .key, character(1)),
        trims = vapply(in_meta, function(m) as.integer(m$pad - need), integer(1)),
        dtypes = dtypes,
        out_keys = okeys,
        pads = epads[epads > 0L],
        out_dtypes = .export_dtypes(graph, s),
        grows = pad_edges,
        need = need,
        ring = takes_ring,
        wq = if (length(wq_keys_of[[.key(s@id)]])) {
          c(wq, list(keys = wq_keys_of[[.key(s@id)]]))
        },
        scan = scans,
        mb = task_mb,
        store_mb = store_mb_comp
      )
      for (j in seq_len(nrow(it))) {
        add_comp_task(j, it[j, ], cd)
      }
    }
  }

  # Store bytes currently pinned by launched-but-unreleased regions:
  # read windows AND compute outputs (both live in the mori store from
  # launch until their last consumer retires).
  mb_store_resident <- 0

  # host_keep (filled after the streaming-sink setup below): store
  # stage ids whose regions the host must read AFTER the drain:
  # combine partials and any sink assembled host-side rather than
  # streamed. Everything else drops as its consumers retire.
  host_keep <- new.env(parent = emptyenv())

  # Drops are batched per harvest sweep: one .daemon_shm_drop round
  # per pool instead of one per retiring task.
  pending_drop <- character(0)
  pending_drop_mb <- 0
  unmapped_mb <- 0
  queue_drop <- function(keys) {
    for (rk in keys) {
      if ((store_users[[rk]] %||% 0L) > 0L) {
        next
      }
      sid <- task_stage_of[[rk]]
      if (is.null(sid)) {
        next
      } # no store region (fetch)
      if (isTRUE(host_keep[[.key(sid)]])) {
        next
      }
      task_stage_of[[rk]] <- NULL # drop at most once
      mb_store_resident <<- mb_store_resident - tasks[[rk]]$store_mb
      pending_drop <<- c(pending_drop, rk)
      pending_drop_mb <<- pending_drop_mb + tasks[[rk]]$store_mb
    }
    invisible(NULL)
  }
  # Throttled: the host gc() that releases mori mappings costs seconds
  # on a large host heap, so drops flush on a clock, not per sweep.
  # Budget ACCOUNTING (mb_store_resident) is decremented at queue time,
  # so read launches unblock immediately; only the physical unlink
  # lags, bounded by the flush interval: and by BYTES: once the
  # queued-but-unfreed regions exceed a quarter of the read budget,
  # flush regardless of the clock, or true shm high-water exceeds the
  # budget by everything launched inside one flush window.
  last_flush <- Sys.time()
  flush_drops <- function(force = FALSE) {
    if (length(pending_drop) == 0L) {
      return(invisible(NULL))
    }
    if (
      !force &&
        pending_drop_mb < 0.25 * read_budget_mb &&
        difftime(Sys.time(), last_flush, units = "secs") < 5
    ) {
      return(invisible(NULL))
    }
    regs <- .glue("r{run_id}_{pending_drop}")
    for (p in profiles) {
      mirai::everywhere(
        asNamespace("garry")$.daemon_shm_drop(regs),
        regs = regs,
        .compute = p
      )
    }
    # Per-key exists() filter: ls() on the store env sorts every key
    # (~40 ms at 20k entries) once per flush.
    rm(
      list = pending_drop[vapply(
        pending_drop,
        exists,
        logical(1),
        envir = chunk_vals,
        inherits = FALSE
      )],
      envir = chunk_vals
    )
    pending_drop <<- character(0)
    unmapped_mb <<- unmapped_mb + pending_drop_mb
    pending_drop_mb <<- 0
    last_flush <<- Sys.time()
    # The host munmaps its handles, and regions free once unlinked. A gc costs
    # 0.1 s and up, a sixth of a small run, so small regions wait for bigger ones.
    if (unmapped_mb >= .daemon_gc_budget_mb) {
      gc(FALSE)
      unmapped_mb <<- 0
    }
    invisible(NULL)
  }

  # On task completion: the task's own output may already be dead (a
  # streamed sink chunk with no compute consumers), and each store
  # input it consumed loses one user.
  release_store <- function(k) {
    queue_drop(k)
    deps <- task_ins[[k]]
    if (is.null(deps) || length(deps) == 0L) {
      return(invisible(NULL))
    }
    for (rk in deps) {
      store_users[[rk]] <- store_users[[rk]] - 1L
    }
    queue_drop(deps)
  }

  # Idle-time jit warm-up: each compute daemon (a routed profile)
  # compiles the plan's kernels, in plan order, only while it has no
  # task running, one kernel at a time (measured: cold 1.45 s vs warmed
  # 0.61 s per tail chunk). A daemon that meets a kernel before its
  # warm-up still compiles it on first use (the task ships its kernel),
  # so a ready task waits behind at most one compile. Map kernels warm on every
  # profile, scan kernels only on the designated scan profiles. A
  # compute profile is one daemon without a dispatcher, so its tasks run
  # in submission order: a kernel is marked warm on its profile when the
  # warm-up is SENT, and later tasks there ship the cache key alone (the
  # closure is MBs) and run after the compile. A failed warm-up clears
  # the mark; a key-only task that still misses is resent with the
  # closure (the garry_jit_miss path).
  warm_queue <- list()
  warm_inflight <- list()
  if (length(warm_specs)) {
    warm_specs <- warm_specs[
      !duplicated(
        vapply(warm_specs, `[[`, character(1), "ck")
      )
    ]
    for (p in comp_profs) {
      q <- Filter(function(sp) !isTRUE(sp$scan) || p %in% scan_profs, warm_specs)
      if (length(q)) warm_queue[[p]] <- q
    }
  }
  # A failed warm-up leaves that kernel cold there, so its first real
  # task compiles it, and raises if the failure was the kernel's own.
  # One warning a run.
  warm_warned <- FALSE
  warm_failed <- function(p, w, why) {
    prof_warm[[.pw_key(p, w$ck)]] <- FALSE
    log_line("warm_fail", w$key, pool = p)
    if (!warm_warned) {
      warm_warned <<- TRUE
      cli::cli_warn(
        c(
          "a kernel warm-up failed on {.val {p}}; its first task compiles it instead.",
          "x" = "{why}"
        ),
        class = c("garry_warmup_warning", "garry_warning")
      )
    }
  }
  # Collect finished warm-ups (TRUE when one finished).
  warm_collect <- function() {
    done_any <- FALSE
    for (p in names(warm_inflight)) {
      w <- warm_inflight[[p]]
      if (mirai::unresolved(w$h)) next
      if (inherits(w$h$data, "errorValue")) {
        warm_failed(p, w, .task_failure(w$h$data))
      }
      .task_landed(log_line, w$key, w$h$data)
      if (isTRUE(w$scan)) prof_cold_busy[[p]] <- FALSE
      prof_slots[[p]] <<- prof_slots[[p]] - 1L
      warm_inflight[[p]] <<- NULL
      done_any <- TRUE
    }
    done_any
  }
  # Collect, then launch the next unwarmed kernel on every idle compute
  # profile.
  warm_step <- function() {
    done_any <- warm_collect()
    for (p in names(warm_queue)) {
      if (!is.null(warm_inflight[[p]]) || prof_slots[[p]] > 0L) next
      q <- warm_queue[[p]]
      while (length(q) && isTRUE(prof_warm[[.pw_key(p, q[[1L]]$ck)]])) q <- q[-1L]
      if (!length(q)) {
        warm_queue[[p]] <<- NULL
        next
      }
      sp <- q[[1L]]
      warm_queue[[p]] <<- q[-1L]
      key <- paste0("warm", sp$stage, "_c1")
      warm_inflight[[p]] <<- list(
        h = .task_launch(
          tl,
          key,
          quote(asNamespace("garry")$.daemon_warm_jit(list(sp))),
          sp = sp,
          .compute = p,
          .pool = "comp",
          .slot = p
        ),
        ck = sp$ck,
        key = key,
        scan = isTRUE(sp$scan)
      )
      prof_slots[[p]] <<- prof_slots[[p]] + 1L
      prof_warm[[.pw_key(p, sp$ck)]] <- TRUE
      if (isTRUE(sp$scan)) prof_cold_busy[[p]] <- TRUE
    }
    done_any
  }

  # Region-aware stage chunk lookup. A stage's chunks live under its
  # own task keys UNLESS source_deps says otherwise: a FUSED stage's
  # chunks ride its source's read tasks, and an UNFUSED coarse-split
  # source's chunks are elements of its read-window regions: both
  # store per-chunk data under READ task keys. Everything that
  # retrieves stage chunks by (stage, j): the streaming writers, the
  # post-drain assembly, in-memory multi-export: goes through here.
  # (Gating this on the placement table lost SPLIT source sinks:
  # defect hunt H1, 2026-07-30.)
  chunk_of <- function(sid, j) {
    r <- chunk_ref(sid, j)
    if (is.null(r$el)) {
      return(r$v)
    }
    stats::setNames(list(r$v[[r$el]]), sub("\x1f.*$", "", r$el))
  }
  # Un-extracted form for writer-daemon dispatch: the SHARED value (a
  # ~30-byte region name over the wire), the element to extract on the
  # daemon, and the store region key the write consumes.
  chunk_ref <- function(sid, j) {
    deps <- source_deps[[.key(sid)]]
    if (is.null(deps)) {
      rk <- .glue("s{sid}_c{j}")
      return(list(v = chunk_vals[[rk]], el = NULL, rk = rk))
    }
    el <- source_elts[[.key(sid)]]
    list(
      v = chunk_vals[[deps[[j]]]],
      el = if (!is.null(el)) el[[j]],
      rk = deps[[j]]
    )
  }
  # Task -> sink chunk map for a streaming writer: which chunks of
  # stage `st_id` land when task `key` completes. One chunk per task
  # for ordinary stages; a fused stage under a coarse read lands ALL of
  # a read window's chunks at once.
  sink_task_map <- function(st_id, n_chunks) {
    deps <- source_deps[[.key(st_id)]]
    keys <- if (is.null(deps)) {
      .glue("s{st_id}_c{seq_len(n_chunks)}")
    } else {
      deps
    }
    split(seq_len(n_chunks), keys)
  }

  # Streaming sink writes (phase 11.3): with a file destination, each
  # sink chunk writes the moment it lands, so all but the last band's
  # writes hide under the drain instead of running serially after it.
  # (The single-threaded executor writes at the end. Either way the files
  # build in the temporary directories of .collect_write().)
  wnodata <- as.numeric(nodata)
  multi <- length(plan@sinks) > 1L
  # Streamed writes go to the writer daemon: the host creates the outputs
  # (geometry, bands, nodata), closes its handles, and ships each landed
  # chunk's REGION NAME to the writer. The f64->file conversion transients
  # then live in one reapable process instead of on the dispatch thread
  # (measured 15-19 GB of oscillating host anon on a 4.2 Mpx multi-export
  # scan tail). A writer that has gone fails the run.
  writer_on <- !is.null(path) && (multi || sink@kind != "reduce_combine")
  wr_inflight <- list()
  if (writer_on) {
    .assert_pools_alive("garry_write")
    # Abort path: queued writer tasks still map store regions by name,
    # so this handler must run BEFORE the earlier-registered
    # .daemon_shm_clear handler unlinks them (`after = FALSE` prepends;
    # on.exit otherwise runs in registration order).
    on.exit(.writer_settle(wr_inflight), add = TRUE, after = FALSE)
  }
  # Every sink that streams gets its output now and writes each chunk the
  # moment its stage task lands (for a FUSED sink stage: the moment its
  # source's read task lands). A reduce_combine sink combines on the host,
  # and a sink no producer can quantize takes the host tail too: both
  # write after the drain.
  stream_sink <- function(st, nid, grid, p, bands) {
    if (st@kind == "reduce_combine" || !.wq_stream_ok(st, nid)) {
      return(NULL)
    }
    it <- chunk_iter(.stage_out_chunks(plan, st))
    gdal_close_output(.sink_output(p, grid, wnodata, bands, wspec), p)
    list(
      sid = st@id,
      key = .key(nid),
      it = it,
      pad = .exec_export_pad(st, nid),
      dtype = wspec$dtype %||% grid@dtype,
      path = p,
      task_j = sink_task_map(st@id, nrow(it))
    )
  }
  stream_sinks <- list()
  if (!is.null(path) && multi) {
    for (kk in seq_along(plan@sinks)) {
      nid <- plan@sinks[[kk]]
      nm <- names(plan@sinks)[[kk]]
      ngrid <- graph_get(graph, nid)@grid
      stream_sinks[[nm]] <- stream_sink(
        .stage_of_node(plan, nid),
        nid,
        ngrid,
        .sink_paths(path, nm)[[nm]],
        .sink_band_names(band_names, nm, ngrid)
      )
    }
  } else if (!is.null(path)) {
    stream_sinks$sink <- stream_sink(
      sink,
      sink@members[[length(sink@members)]],
      sink@grid,
      path,
      band_names
    )
  }

  # Post-drain needs: combine closures run host-side on their partial
  # stage's chunks, and any sink NOT covered by a streaming writer is
  # assembled host-side from its stage's chunks. Those stages' regions
  # must survive consumer refcounting; everything else is dropped as
  # the frontier passes.
  for (s in plan@stages) {
    if (s@kind == "reduce_combine") {
      host_keep[[.key(s@inputs[[1L]])]] <- TRUE
    }
  }
  for (nid in unique(sink_nids)) {
    st <- .stage_of_node(plan, nid)
    if (st@kind == "reduce_combine") {
      next
    } # parts kept above
    streamed <- vapply(
      stream_sinks,
      function(sp) sp$sid == st@id && sp$key == .key(nid),
      logical(1)
    )
    if (!any(streamed)) host_keep[[.key(st@id)]] <- TRUE
  }

  # Effective read budget: never below 1.25x the widest stage's
  # co-resident window set (see max_set_mb above).
  read_budget_mb <- max(read_budget_mb, 1.25 * max_set_mb)

  # ---- Memory admission control -------------------------------------
  # A configured budget is a CAP, not an entitlement: it assumes the
  # machine is garry's alone, and when the calling session already holds
  # tens of GB (model fits, point tables, a previous stage's outputs)
  # that overcommits and the run dies mid-drain. Fit both budgets inside
  # a fraction of what is ACTUALLY available, and re-read during the
  # drain so a host that grows while we run tightens the gates rather
  # than racing it to the OOM killer.
  #
  # Floors keep progress possible: compute always admits its largest
  # single task (the in-flight gates already allow one over-budget task
  # through), and reads always admit one window. A budget below those
  # serialises rather than deadlocks.
  mem_frac <- garry_opt("exec_ram_fraction")
  read_budget_cfg <- read_budget_mb
  task_mb_max <- 0
  for (k in ls(tasks)) {
    t2 <- tasks[[k]]
    if (identical(t2$pool, "comp")) {
      task_mb_max <- max(task_mb_max, t2$mb)
    }
  }
  store_mb_max <- max(c(
    0,
    vapply(
      ls(stage_store_mb),
      function(k) stage_store_mb[[k]],
      numeric(1)
    )
  ))
  mem_last_check <- Sys.time()
  # a dead daemon's tasks never resolve
  idle <- .idle_step(c(profiles, if (writer_on) "garry_write"))
  rss_excess_seen <- 0
  # Fleet anon at RUN START, plus a trailing window of unmanaged samples
  # (dask's managed / unmanaged-old / unmanaged-recent distinction).
  # Daemons legitimately RETAIN memory between tasks: XLA buffer pools;
  # a warmed scan daemon holds ~6.5 GB: and that retained pool is
  # REUSED by the next task, not additive to it. The first SI run of the
  # correction compared measured anon against in-flight bytes alone, so
  # warmed standing state read as drift, the budget floored mid-tail and
  # the scans serialised (2026-07-31). The correction therefore
  # tolerates the run-start baseline AND anything sustained across the
  # trailing window (~30 s at the 5 s refresh cadence): only RECENT
  # growth beyond what in-flight work explains tightens the budget:
  # which is exactly the estimate-defect class (a burst of
  # underestimated working sets) it exists to catch. The shm clamp and
  # the avail-RAM pool remain the hard backstops for slow leaks.
  rss_baseline <- .garry_fleet_anon_mb(.garry_state$pool_pids)
  if (!is.finite(rss_baseline)) {
    rss_baseline <- 0
  }
  rss_hist <- rep(NA_real_, 6L) # trailing (anon - inflight) samples
  refresh_mem_budgets <- function(announce = FALSE) {
    b <- .store_budget(read_budget_cfg, store_mb_max, mb_store_resident, mem_frac)
    if (is.null(b)) {
      return(invisible(NULL))
    }
    avail <- b$avail
    rb <- b$read
    # compute takes the pool past the reads' share
    cb <- max(task_mb_max, b$pool - b$ram_read)
    if (b$tight) flush_drops(force = TRUE)
    # Measured per-daemon memory correction (dask's managed-vs-process
    # distinction, transplanted into the admission model): when the
    # fleet's measured anonymous RSS exceeds the modelled in-flight
    # working sets plus a per-daemon client allowance, some estimate is
    # drifting low: shrink the compute budget by the excess, so the
    # next estimate defect becomes a throughput dip and a log line
    # instead of an OOM. The inform is throttled to genuine growth so a
    # persistently tight run does not spam every 5 s refresh.
    anon <- .garry_fleet_anon_mb(.garry_state$pool_pids)
    if (is.finite(anon) && isTRUE(garry_opt("rss_correction"))) {
      allow <- length(.garry_state$pool_pids) * .xla_client_mb
      unman <- anon - mb_inflight
      old_unman <- suppressWarnings(min(rss_hist, na.rm = TRUE))
      if (!is.finite(old_unman)) {
        old_unman <- rss_baseline
      }
      tolerated <- max(rss_baseline, old_unman)
      excess <- unman - (tolerated + allow)
      rss_hist <<- c(rss_hist[-1L], unman)
      if (excess > 0) {
        cb <- max(task_mb_max, cb - excess)
        if (excess > 1.2 * rss_excess_seen) {
          rss_excess_seen <<- excess
          cli::cli_inform(paste0(
            "garry: fleet anon RSS {round(anon)} MB exceeds modelled ",
            "{round(mb_inflight + tolerated + allow)} MB (recent growth ",
            "{round(excess)} MB); compute budget tightened to ",
            "{round(cb)} MB"
          ))
        }
      }
    }
    # Announce only on a genuine squeeze: reads capped below their
    # configured budget, or the pool cannot hold even two compute chunks.
    if (
      announce &&
        (rb < read_budget_cfg ||
          (task_mb_max > 0 && cb < 2 * task_mb_max))
    ) {
      cli::cli_inform(paste0(
        "garry: {round(avail/1024, 1)} GiB available; in-flight compute ",
        "budget {round(cb)} MB, resident reads {round(rb)} MB (configured ",
        "{round(read_budget_cfg)})"
      ))
    }
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
      cli::cli_warn(
        paste0(
          "a single compute chunk is estimated at {chunk_sz}, above the ",
          "{budget_sz} execution budget; ",
          "it will run one at a time. Lower {.code garry.chunk_target_px} or ",
          "{.code garry.ram_budget_mb} to chunk finer."
        ),
        class = c("garry_memory_warning", "garry_warning")
      )
    }
  })

  # Scan order: priority first (stable within a priority level), then
  # WINDOW-major within a priority: tasks sharing a chunk/window
  # ordinal sort together across sibling stages. Insertion order is
  # stage-major (band 1's windows, band 2's windows, ...), so a
  # multi-input stage's per-window input set would otherwise only
  # complete after nearly the whole stage's reads launched: under the
  # read byte budget that degrades to a serial trickle. Window-major
  # makes each window's cross-band set resident and releasable as a
  # unit, and lands the same source window's per-band reads together
  # in time, so pixel-interleaved sources decompress each window ~once
  # per reader (GDAL block cache) instead of once per band.
  # Fetch tasks are prio 1, everything else 2, so the read pool
  # downloads flat-out while any fetch is pending and only then
  # takes assembles: interleaving them measured the fleet at
  # ~18 MB/s where pure fetching sustains 40-50 MB/s (a local
  # assemble idles its reader's connection for ~1 s).
  task_keys <- ls(tasks)
  ord_win <- vapply(
    task_keys,
    function(k) {
      n <- suppressWarnings(as.integer(sub("^s\\d+_[rc](\\d+)$", "\\1", k)))
      if (is.na(n)) 0L else n
    },
    integer(1)
  )
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
  n_inflight <- c(read = 0L, comp = 0L)
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
  # task always drains a saturated store. For a kernel task the escape
  # admits one PER COMPUTE DAEMON, not one in total: kernel tasks are
  # what retire the regions filling the store, so a single-task escape
  # made a full store keep itself full. The SI tail measured it: every
  # compute task pins a small output region (~3 MB), the resident reads
  # sat above the budget for most of the drain, and the compute pool ran
  # one task at a time with its second daemon 7% busy (2026-10-23). A
  # fetch-backed assemble also runs on the compute pool, but it adds a
  # read region rather than retiring one, so it keeps the single escape.
  # Each escaped task pins its output until its consumers retire it, so
  # the store can run past the budget by the outputs still waiting on
  # theirs; the /dev/shm backstop in refresh_mem_budgets() bounds it.
  store_ok_comp <- function(t) {
    .store_gate_comp(
      mb_store_resident,
      t$store_mb,
      read_budget_mb,
      n_inflight[["comp"]],
      n_comp,
      kernel = !is.null(t$ck)
    )
  }
  # The in-flight BYTE budget covers every byte-accounted task, not
  # just comp-pool ones: a FUSED read runs its kernel's whole working
  # set on the reader, so it is compute in disguise and must ride the
  # same budget (a fleet of cold fused reads otherwise stacks N XLA
  # ramps on whatever else holds the machine: measured at crop=0 with
  # the whole-AOI embedding staging resident). The escape is accordingly "nothing
  # byte-accounted in flight", so one over-budget task always runs. It counts
  # tasks: the running sum keeps a rounding residue once they have landed.
  # Cold-scan concurrency is bounded STRUCTURALLY, by K scan profiles
  # with one cold compile each (design/routed-dispatch.md).
  comp_ok <- function(t) {
    n_mb_inflight == 0L ||
      mb_inflight + t$mb <= comp_budget_mb
  }
  # Writer-daemon bookkeeping. Each dispatched write holds a consumer
  # reference on the producing store region (the writer maps it by
  # name), released when the write task resolves: so regions free on
  # exactly the same refcount discipline as compute consumers.
  wr_seq <- 0L
  dispatch_write <- function(sid, j, wpath, it, skey, pad, dtype) {
    ref <- chunk_ref(sid, j)
    store_users[[ref$rk]] <- (store_users[[ref$rk]] %||% 0L) + 1L
    wr_seq <<- wr_seq + 1L
    key <- paste0("w", sid, "_c", j)
    wr_inflight[[as.character(wr_seq)]] <<- list(
      rk = ref$rk,
      key = key,
      h = .task_launch(
        tl,
        key,
        quote(asNamespace("garry")$.daemon_write_chunk(
          wpath,
          xo,
          yo,
          val,
          skey,
          el,
          pad,
          dtype,
          nodata = nd,
          n_chunks = nc
        )),
        wpath = wpath,
        xo = it$x_off[[j]],
        yo = it$y_off[[j]],
        val = ref$v,
        skey = skey,
        el = ref$el,
        pad = pad,
        dtype = dtype,
        nd = wnodata,
        nc = nrow(it),
        .compute = "garry_write",
        .pool = "write",
        .mb = tasks[[ref$rk]]$store_mb
      )
    )
    invisible(NULL)
  }
  harvest_writes <- function() {
    any_done <- FALSE
    for (wk in names(wr_inflight)) {
      w <- wr_inflight[[wk]]
      if (mirai::unresolved(w$h)) {
        next
      }
      if (inherits(w$h$data, "errorValue")) {
        .task_abort(
          "sink write failed on the writer daemon",
          w$h$data,
          "garry_write_error",
          region = w$rk
        )
      }
      .task_landed(log_line, w$key, w$h$data)
      store_users[[w$rk]] <- store_users[[w$rk]] - 1L
      queue_drop(w$rk)
      wr_inflight[[wk]] <<- NULL
      any_done <- TRUE
    }
    any_done
  }

  # O(1) readiness: per-task unmet-dep counters decremented through a
  # reverse index on completion.
  dep_left <- new.env(parent = emptyenv()) # task -> unmet dep count
  dependents <- new.env(parent = emptyenv()) # task -> tasks waiting on it
  for (k in task_keys) {
    d <- unique(tasks[[k]]$deps)
    dep_left[[k]] <- length(d)
    for (dk in d) {
      dependents[[dk]] <- c(dependents[[dk]], k)
    }
  }
  n_done <- 0L
  is_ready <- function(k) dep_left[[k]] == 0L
  remaining <- function() n_done < n_total
  progress <- isTRUE(garry_opt("progress"))
  # daemon-side start times ride the task log (see .task_mirai)
  tl <- .task_log_open(
    run_id,
    c(
      read = .gd_n_compute("garry_read"),
      comp = length(comp_profs),
      if (writer_on) c(write = 1L)
    )
  )
  log_line <- tl$line
  t_drain0 <- unclass(Sys.time()) # zero-dep tasks are ready at drain start
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
      while (
        first_pending <= n_total &&
          tasks[[task_order[[first_pending]]]]$state != "pending"
      ) {
        first_pending <- first_pending + 1L
      }
      for (k in task_order[seq.int(
        first_pending,
        length.out = max(0L, n_total - first_pending + 1L)
      )]) {
        t <- tasks[[k]]
        if (t$state != "pending") {
          next
        }
        if (t$pool == "read") {
          if (n_inflight[["read"]] >= cap_read) {
            next
          }
          if (!read_ok(t)) {
            next
          }
          # Fused reads carry a kernel working set: ride the compute
          # byte budget too, or a cold fleet ramps N XLA working sets
          # at once regardless of what else holds the machine.
          if (t$mb > 0 && !comp_ok(t)) next
        } else {
          if (!comp_ok(t)) {
            next
          }
          # Compute tasks pin their OUTPUT region from launch, and
          # fetch-backed assembles pin read-store bytes like any read:
          # gate both by the store budget, with the comp-pool escape so
          # a saturated store still drains (see store_ok_comp).
          if (t$store_mb > 0 && !store_ok_comp(t)) {
            next
          }
          cprof <- pick_comp_prof(t)
          if (is.null(cprof)) {
            next
          } # every eligible profile busy/at depth
        }
        if (!is_ready(k)) {
          next
        }
        prof <- if (t$pool == "read") read_prof else cprof
        # stamped BEFORE dispatch: a daemon can start the task before
        # the launch call returns, and queue time must not go negative
        t_launch <- Sys.time()
        inflight[[k]] <- if (is.null(t$ck)) {
          t$launch(prof)
        } else {
          # Compute-pool launches of warmed kernels ship the cache key
          # only when the CHOSEN profile provably holds the kernel; a
          # cold profile gets the closure and compiles on first use.
          warm_now <- t$pool == "comp" &&
            isTRUE(prof_warm[[.pw_key(prof, t$ck)]])
          t$launch(prof, with_fn = !warm_now)
        }
        tasks[[k]]$prof <- prof
        if (t$pool == "comp") {
          prof_slots[[prof]] <- prof_slots[[prof]] + 1L
          if (
            !is.null(t$ck) &&
              isTRUE(t$scan) &&
              !isTRUE(prof_warm[[.pw_key(prof, t$ck)]])
          ) {
            prof_cold_busy[[prof]] <- TRUE
          }
        }
        n_inflight[[t$pool]] <- n_inflight[[t$pool]] + 1L
        mb_inflight <- mb_inflight + t$mb
        n_mb_inflight <- n_mb_inflight + (t$mb > 0)
        # Read-producing tasks pin their region from launch, not from
        # completion (fetch-backed assembles run on the compute pool but
        # pin store bytes just the same).
        mb_store_resident <- mb_store_resident + t$store_mb
        tasks[[k]]$state <- "running"
        log_line(
          "launch",
          k,
          pool = t$pool,
          # routed profiles put the daemon identity in the slot
          # column: free per-daemon task attribution in
          # garry_task_report (the observability gap the deep
          # review deferred)
          slot = if (t$pool == "comp") prof else t$pool,
          mb = round(t$mb, 1),
          store_mb = round(t$store_mb, 1),
          ready = formatC(
            tasks[[k]]$t_ready %||% t_drain0,
            format = "f",
            digits = 3
          ),
          time = t_launch
        )
      }
    }
    if (length(warm_queue) || length(warm_inflight)) {
      # a finished warm-up frees its daemon after this pass's launch
      # scan: rescan before judging deadlock or harvesting
      if (warm_step()) {
        scan_needed <- TRUE
        next
      }
    }
    if (length(inflight) == 0L && length(warm_inflight) == 0L) {
      blocked <- task_order[[first_pending]]
      .scheduler_deadlock(
        n_total - n_done,
        blocked,
        tasks[[blocked]]$pool,
        mb_store_resident,
        read_budget_mb,
        comp_budget_mb
      )
    }
    harvested <- FALSE
    for (k in names(inflight)) {
      h <- inflight[[k]]
      if (!mirai::unresolved(h)) {
        if (inherits(h$data, "errorValue")) {
          # A key-only launch found the daemon's jit cache cold (the
          # cache was wiped, or warmth outlived it): resend once with
          # the kernel, and clear the mark, or every later task of this
          # kernel misses too. Resend to the SAME profile: the miss
          # identifies the one daemon that lacks it.
          if (
            "garry_jit_miss" %in% attr(h$data, "condition.class", exact = TRUE) &&
              !isTRUE(tasks[[k]]$resent)
          ) {
            tasks[[k]]$resent <- TRUE
            if (!is.null(tasks[[k]]$ck)) {
              prof_warm[[.pw_key(tasks[[k]]$prof, tasks[[k]]$ck)]] <- FALSE
            }
            log_line("resend", k, pool = tasks[[k]]$prof)
            inflight[[k]] <- tasks[[k]]$launch(tasks[[k]]$prof, with_fn = TRUE)
            next
          }
          .task_abort(
            .glue("task {k} failed on daemon"),
            h$data,
            task = k,
            stage = task_stage_of[[k]],
            pool = tasks[[k]]$pool
          )
        }
        # the daemon's own start and end times (same host clock), so
        # queue time (start - launch) and harvest lag (done - end)
        # separate from run time (end - start)
        chunk_vals[[k]] <- .task_landed(log_line, k, h$data)
        tasks[[k]]$state <- "done"
        n_done <- n_done + 1L
        for (k2 in dependents[[k]]) {
          dep_left[[k2]] <- dep_left[[k2]] - 1L
          if (dep_left[[k2]] == 0L) {
            tasks[[k2]]$t_ready <- unclass(Sys.time())
          }
        }
        inflight[[k]] <- NULL
        pool_k <- tasks[[k]]$pool
        n_inflight[[pool_k]] <- n_inflight[[pool_k]] - 1L
        if (pool_k == "comp") {
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
        mb_inflight <- mb_inflight - tasks[[k]]$mb
        n_mb_inflight <- n_mb_inflight - (tasks[[k]]$mb > 0)
        harvested <- TRUE
        for (sp in stream_sinks) {
          if (is.null(sp$task_j[[k]])) {
            next
          }
          for (j in sp$task_j[[k]]) {
            dispatch_write(sp$sid, j, sp$path, sp$it, sp$key, sp$pad, sp$dtype)
          }
          log_line("write", k)
        }
        release_store(k)
        # Eager fetch-cache cleanup: a fetch-backed source stage's
        # window files unlink once its last read (assemble) task is
        # done: bounds the tmpfs cache to slices still assembling.
        if (startsWith(k, "s")) {
          sk <- sub("^s(\\d+)_.*$", "\\1", k)
          left <- fetch_reads_left[[sk]]
          if (!is.null(left)) {
            fetch_reads_left[[sk]] <- left - 1L
            if (left <= 1L) {
              done_files <- character(0)
              for (ff in unique(fetch_files_of[[sk]])) {
                n_left <- (fetch_holders[[ff]] %||% 1L) - 1L
                fetch_holders[[ff]] <- n_left
                if (n_left <= 0L) done_files <- c(done_files, ff)
              }
              unlink(done_files)
              rm(list = sk, envir = fetch_files_of)
            }
          }
        }
      }
    }
    if (length(wr_inflight) > 0L && harvest_writes()) {
      harvested <- TRUE
    }
    if (harvested) {
      flush_drops()
      scan_needed <- TRUE
    }
    # Re-read MemAvailable on a clock: the caller's own session can
    # grow while we drain (host-side fits, assembled sinks), and the
    # gates must follow the machine rather than the configuration. The
    # clock runs whether or not anything landed: a stall with every
    # daemon inside a long task is when memory moves fastest.
    if (difftime(Sys.time(), mem_last_check, units = "secs") >= 5) {
      refresh_mem_budgets()
      mem_last_check <- Sys.time()
      scan_needed <- TRUE
      # Sample measurement vs model on the same clock: per-daemon
      # anon RSS and the modelled in-flight/resident bytes. This is
      # the diverging-lines plot every memory postmortem rebuilt by
      # hand (crop=0 flood, scan-compile OOM). The host process, the
      # binding cgroup, /dev/shm and the admission budgets ride along:
      # a container OOM counts all of them, and the budgets show when
      # the RSS correction bit.
      if (tl$timed) {
        # one timestamp per sweep: the report sums a sweep's rows
        sweep_t <- Sys.time()
        .task_log_memory(log_line, sweep_t)
        log_line(
          "model",
          "-",
          time = sweep_t,
          mb = round(mb_inflight, 1),
          store_mb = round(mb_store_resident, 1)
        )
        log_line(
          "budget",
          "-",
          mb = round(comp_budget_mb, 1),
          store_mb = round(read_budget_mb, 1),
          time = sweep_t
        )
      }
    }
    if (
      progress &&
        difftime(Sys.time(), last_report, units = "secs") > 5
    ) {
      n_inf <- length(inflight)
      cli::cli_inform("garry: {n_done}/{n_total} tasks done, {n_inf} in flight")
      last_report <- Sys.time()
    }
    if (!harvested) {
      idle()
    }
  }

  # Host-side: combines, then sink retrieval (mirrors execute_plan).
  flush_drops(force = TRUE)
  warm_collect() # a warm-up still compiling keeps its launch row alone
  log_line("drain_end", "-")
  on.exit(log_line("host_end", "-"), add = TRUE)
  # Outstanding writer-daemon writes must land before outputs close or
  # host-side retrieval begins; then the writer releases its handles.
  if (writer_on) {
    idle <- .idle_step("garry_write")
    while (length(wr_inflight) > 0L) {
      if (harvest_writes()) {
        flush_drops()
      } else {
        idle()
      }
    }
    .writer_close()
    flush_drops(force = TRUE)
  }
  out_of <- function(s) {
    it <- chunk_iter(.stage_out_chunks(plan, s))
    lapply(seq_len(nrow(it)), function(j) chunk_of(s@id, j))
  }

  # Streaming write already put every sink chunk on disk as it landed.
  if (!multi && length(stream_sinks)) {
    return(invisible(path))
  }

  combine_vals <- new.env(parent = emptyenv())
  for (s in plan@stages) {
    if (s@kind != "reduce_combine") {
      next
    }
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
    if (st@kind == "reduce_combine") {
      list(combine_vals[[.key(st@id)]])
    } else {
      out_of(st)
    }
  }
  streamed_path <- function(nm) stream_sinks[[nm]]$path
  .exec_sink_tail(
    plan,
    graph,
    chunks_of = chunks_of,
    path = path,
    wspec = wspec,
    nodata = nodata,
    band_names = band_names,
    streamed_path = streamed_path
  )
}

# Nothing in flight and nothing can launch: every remaining task sits
# behind a gate or a dependency that will never open.
.scheduler_deadlock <- function(n_left, blocked, pool, store_mb, read_mb, comp_mb) {
  cli::cli_abort(
    c(
      "scheduler deadlock: {n_left} task{?s} left, none can run. This is a garry bug: please report it.",
      "x" = "{blocked} (pool {pool}) is the first blocked.",
      "x" = "store {round(store_mb)} of {round(read_mb)} MB, compute budget {round(comp_mb)} MB.",
      "i" = "A larger {.code garry.read_budget_mb} may let the run finish."
    ),
    class = c("garry_scheduler_error", "garry_error")
  )
}

# Would the scheduler's fetch stage serve this read? A GTI index with
# garry's sidecar, a slice filter, and remote items in that slice (any
# item under garry.fetch = "force"): its windows then download to local
# files in parallel before the reads. Mirrors prepare_fetch() in
# execute_plan_mirai(), so the read-only route can leave these reads to
# the scheduler.
.read_would_fetch <- function(rpath, roo) {
  ix <- .fetch_index(rpath, garry_opt("fetch"))
  sl <- .gti_slice_of(roo)
  if (is.null(ix) || is.null(sl) || is.na(sl)) {
    return(FALSE)
  }
  any(ix$meta$entries$slice == sl & ix$fetch)
}

# A GTI index the fetch stage can serve under `mode`, or NULL: its sidecar
# and which of its entries fetch (remote ones, every one under "force").
.fetch_index <- function(rpath, mode) {
  if (mode == "direct" || length(rpath) != 1L || !startsWith(rpath, "GTI:")) {
    return(NULL)
  }
  meta <- .gti_meta(rpath)
  if (!all(c("slice", "location") %in% names(meta$entries))) {
    return(NULL)
  }
  fetch <- mode == "force" | grepl("^/vsi", meta$entries$location)
  if (any(fetch)) list(meta = meta, fetch = fetch)
}
