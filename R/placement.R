#' @include scheduler.R
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Placement pass (design/placement-cost-pass.md, amended by
# design/scheduling-review-2026-07-29.md).
#
# Decides, per source_read -> compute chain, whether the compute stage
# runs fused on its source's read tasks or materialises through the
# compute pool. Runs at EXECUTE time, not plan time: the decision is a
# function of runtime resources (pool widths, RAM), so it must not be
# baked into a reusable Plan. The result is a side table consumed by
# execute_plan_mirai's task build; the single-threaded oracle and the
# gdal-direct routes never see it.
#
# Pool assignment for fetch-backed assembles stays in the scheduler: it
# depends on prepare_fetch's stateful index probing and is orthogonal to
# fuse-vs-materialise.
# ---------------------------------------------------------------------------

# Cost-mode constants. Sustained per-core throughput of jitted kernels
# (GFLOP/s) and effective /dev/shm copy bandwidth (MB/s): order-of-magnitude
# figures, as the decisions they separate differ by orders of magnitude.
.cost_gflops_core <- 4
.cost_shm_bw_mbs <- 2000
# Parallel efficiency of a compute pool of all-cores clients against
# spread-out narrow ones: 2 such daemons measured 81.4 win/s vs 159.8 for
# 10 x 2-CPU clients on the MLP kernel shape (spike B,
# design/benchmark-history.md 2026-07-29) = 0.51. Applied to the materialise
# route's compute term:
# without it the model credits the warm pool with machine-wide throughput
# it does not deliver and keeps wide kernels off the readers by a false
# margin.
.cost_comp_efficiency <- 0.55
# Without a reader thread cap (garry.pool_affinity), a kernel above this
# many flops/px never fuses: fusing wide compute onto N uncapped readers
# spawns N all-cores XLA clients, a bigger thread cliff than the 2-daemon
# pool it escapes (scheduling review 2026-07-29). Mask cleanup (~10
# flops/px) fuses either way; a 145-band MLP (~2e4) needs the cap.
.fuse_flops_max <- 128
# Per-reader budget (MB) for a fused kernel's live working set: the read
# window plus its activation cubes at read granularity (see
# .stage_fuse_act_bytes_px). The AEF MLP fits a ~1 Mpx window (~2.4 GB)
# and OOM-killed readers at ~4.2 Mpx (~9 GB).
.fuse_reader_mb <- 2500
# Resident cost (MB) of one XLA CPU client and its kernels on a daemon:
# spike A measured ~277 MB after one trivial jit. Fusion is refused when
# n_read x this does not fit in the RAM the exec budget leaves free.
.xla_client_mb <- 350

# Consumer index and warp-only mask, in ONE pass over the stage list:
# per-stage Filter scans are O(stages^2) in S7 accessor calls, tens of
# seconds at the ~2000-stage scale of a many-band multi-export plan. A
# source that is itself a requested sink still needs reading even when
# its only consumers are warps, or multi-export sink retrieval finds no
# chunks.
.placement_scan <- function(plan) {
  stage_kind <- vapply(plan@stages, function(s) s@kind, character(1))
  consumers_of <- vector("list", length(plan@stages))
  for (t2 in plan@stages) {
    for (i in t2@inputs) {
      consumers_of[[i]] <- c(consumers_of[[i]], t2@id)
    }
  }
  warp_only <- vapply(
    plan@stages,
    function(s) {
      cons <- consumers_of[[s@id]]
      s@kind == "source_read" &&
        length(cons) > 0L &&
        all(stage_kind[cons] == "warp") &&
        plan@sink != s@id &&
        !any(plan@sinks %in% s@members)
    },
    logical(1)
  )
  list(consumers_of = consumers_of, warp_only = warp_only)
}

# Correctness preconditions: which source -> compute chains CAN fuse.
# These are not policy: a violated precondition means fusion is wrong
# (a GPU stage would jit on a reader; a multi-consumer source's other
# consumers would find no stored window; multi-input/multi-export
# kernels do not fit the one-window-in, one-export-out fused task
# body, and a self-join is a two-input kernel over one read). SINK
# stages are eligible since the scheduler's chunk lookup and streaming
# writers became fused-aware (chunk_of/sink_task_map):
# a fused sink's chunks stream from its source's read tasks. They are
# flagged `sinkful` so rules mode can keep the exact phase 12b
# behaviour (sinks stayed materialised). The dtype/halo raw-store
# gates stay in the scheduler: they are per-read-task store decisions,
# not placement.
.placement_candidates <- function(plan, consumers_of, warp_only) {
  out <- list()
  for (C in plan@stages) {
    if (C@kind != "compute") {
      next
    }
    if (!identical(C@device, "cpu")) {
      next
    }
    if (length(C@inputs) != 1L || length(C@input_nodes) != 1L || length(C@exports) != 1L) {
      next
    }
    S <- plan@stages[[C@inputs[[1L]]]]
    if (S@kind != "source_read" || warp_only[[S@id]]) {
      next
    }
    if (length(unique(consumers_of[[S@id]])) != 1L) {
      next
    }
    # A SOURCE that is itself a requested sink must keep its stored
    # window: fusing its only consumer replaces the stored region with
    # the kernel's export and the raw band silently vanishes (defect
    # hunt H1, 2026-07-30).
    if (
      any(plan@sinks %in% S@members) ||
        (length(plan@sinks) == 0L && plan@sink == S@id)
    ) {
      next
    }
    out[[length(out) + 1L]] <- list(
      sid = S@id,
      cid = C@id,
      sinkful = C@id == plan@sink || any(plan@sinks %in% C@members)
    )
  }
  out
}

# Row-tile count and per-task working set of a fused chain over one
# read window. Only pointwise chains tile (no halo, no out_pad): a tile
# of rows is then an exact sub-problem, and .apply_fuse concatenates
# the tiles' exports on device. A kernel taking .ring_cells() never
# tiles: its window over a member gives its stage a halo. The reader
# holds the host read buffer (up to 8 bytes/px/band: an R double matrix
# on the non-raw path), the window's device copy (4 bytes/px/band,
# uploaded whole) and the activations of ONE kernel call; only the
# activations shrink with the tile. .stage_fuse_act_bytes_px prices the
# device copy inside its per-pixel figure, so it is split out here
# rather than counted twice.
.fuse_tiles <- function(graph, C, win_px, win_rows, nb_src) {
  act_px <- .stage_fuse_act_bytes_px(graph, C@members, nb_src)
  dev_px <- 4 * max(1, nb_src)
  act_mb <- win_px * max(0, act_px - dev_px) / 2^20
  in_mb <- win_px * (8 * nb_src + dev_px) / 2^20
  tileable <- C@out_pad == 0L && C@halo == 0L
  tiles <- 1L
  if (tileable) {
    tiles <- as.integer(max(1, min(
      win_rows,
      ceiling(act_mb / garry_opt("ram_budget_mb"))
    )))
  }
  list(tiles = tiles, ws_mb = in_mb + act_mb / tiles, act_mb = act_mb,
       in_mb = in_mb)
}

# The placement pass. Returns the side table the scheduler's task
# build consumes:
#   by_source : env, .key(sid) -> fuse spec (only chains DECIDED fuse);
#               spec fields as the task bodies expect (cid, ck, fn,
#               dtype, out_key, out_pad, out_nb)
#   fused     : env, .key(cid) -> TRUE for fused compute stages
#   table     : data.frame of every candidate with decision + reason
#               (the explain surface)
#
# mode = "rules" fuses every candidate except multi-band (coalesced)
# sources, which keep their consumer on the warm pool. The runtime-resource
# arguments are unused in rules mode; cost mode prices against them.
.plan_placement <- function(
  plan,
  consumers_of,
  warp_only,
  n_read = NULL,
  n_comp = NULL,
  reader_threads = NULL,
  comp_threads = NULL,
  avail_mb = NULL,
  mode = garry_opt("placement")
) {
  if (!mode %in% c("rules", "cost")) {
    .garry_error(
      .glue("unknown placement mode: {mode}"),
      "garry_placement_error"
    )
  }
  graph <- plan@graph
  cands <- .placement_candidates(plan, consumers_of, warp_only)
  by_source <- new.env(parent = emptyenv())
  fused <- new.env(parent = emptyenv())
  cores <- .garry_cores()$logical
  k <- reader_threads %||% NA_real_
  kc <- comp_threads %||% NA_real_
  # Materialise-route compute width: an affinity-capped pool delivers
  # close to its nominal machine-bounded width (0.9 x, conservative
  # from spike B where 10 x 2-CPU clients ~doubled the fat pool); an
  # UNCAPPED pool of all-cores clients delivers only
  # .cost_comp_efficiency of the machine.
  width_mat <- if (is.finite(kc)) {
    min(cores, max(1, n_comp %||% 1) * kc) * 0.9
  } else {
    cores * .cost_comp_efficiency
  }
  rows <- list()
  for (cc in cands) {
    S <- plan@stages[[cc$sid]]
    C <- plan@stages[[cc$cid]]
    nb_src <- length(graph_get(graph, S@members[[1L]])@band)
    flops_px <- cost_fuse <- cost_mat <- move_mb <- NA_real_
    # Fused kernels run per READ window (no chunking). Tiled fused
    # kernels: a pointwise chain's activations scale with the pixels
    # handed to ONE kernel call, so a window wider than `ram_budget_mb`
    # runs as row tiles (see .apply_fuse) and the reader holds the
    # input window plus one tile's activations, not the whole
    # window's. Halo / out_pad chains stay whole-window (tiles = 1).
    win_px <- prod(pmin(
      as.numeric(S@chunks@chunk_dim),
      as.numeric(S@grid@dims[c("x", "y")])
    ))
    win_rows <- min(
      as.numeric(S@chunks@chunk_dim[[2L]]),
      as.numeric(S@grid@dims[["y"]])
    )
    tl <- .fuse_tiles(graph, C, win_px, win_rows, nb_src)
    if (identical(mode, "rules")) {
      # Phase 12b behaviour: sinks stay materialised, and a coalesced
      # multi-band source keeps its consumer on the COMPUTE pool
      # (fusing a wide kernel onto the lean readers would idle the
      # warm pool); single-band non-sink chains (mask cleanup) keep
      # the fusion win.
      decision <- if (cc$sinkful || nb_src > 1L) "comp" else "fuse"
      reason <- if (cc$sinkful) {
        "rules: sink stage keeps its own tasks"
      } else if (nb_src > 1L) {
        "rules: multi-band source stays on the warm pool"
      } else {
        "rules: single-band source-fed chain fuses"
      }
    } else {
      # Cost mode: modelled wall-time contribution of the chain under
      # each route. Fuse runs the kernel on the read fleet (thread
      # width n_read x k, machine-bounded) with nothing crossing shm;
      # materialise ships the read window through shm to the compute
      # pool (whose fat clients are machine-bounded regardless of
      # daemon count). Coarse constants; the separations that matter
      # are orders of magnitude.
      flops_px <- .stage_flops_per_px(graph, C@members)
      px <- prod(as.numeric(S@grid@dims[c("x", "y")]))
      move_mb <- px *
        .node_outer_nb(graph, S@members[[1L]]) *
        (if (identical(S@grid@dtype, "f64")) 8 else 4) /
        2^20
      gf <- .cost_gflops_core * 1e9
      fl <- flops_px * px
      eff_fuse <- if (is.finite(k)) {
        min(cores, max(1, n_read %||% 1) * k)
      } else {
        cores
      }
      cost_fuse <- fl / (gf * eff_fuse)
      cost_mat <- 2 * move_mb / .cost_shm_bw_mbs + fl / (gf * width_mat)
      mem_need <- (n_read %||% 1) * .xla_client_mb
      mem_free <- if (is.null(avail_mb) || is.na(avail_mb)) {
        Inf
      } else {
        avail_mb * (1 - garry_opt("exec_ram_fraction"))
      }
      # One reader holds the input window plus the activations of one
      # kernel call (a tile, or the whole window when untileable).
      # Price that against the per-reader budget; a chain whose
      # working set does not fit materialises (the chunked compute
      # pool handles any size).
      if (is.na(flops_px)) {
        decision <- "comp"
        reason <- "cost: unknown compute cost (scan / opaque custom body)"
      } else if (!is.finite(k) && flops_px > .fuse_flops_max) {
        decision <- "comp"
        reason <- .glue(
          "cost: no reader thread cap and {round(flops_px)} flops/px > ",
          "the {round(.fuse_flops_max)} limit ",
          "(N uncapped XLA clients)"
        )
      } else if (tl$ws_mb > .fuse_reader_mb) {
        decision <- "comp"
        reason <- .glue(
          "cost: fused window working set {round(tl$ws_mb)} MB exceeds ",
          "the {round(.fuse_reader_mb)} MB reader budget ",
          "(window {formatC(win_px / 1e6, format = 'f', digits = 1)} Mpx",
          "{if (tl$tiles > 1L) paste0(' in ', tl$tiles, ' row tiles') else ' at read granularity'})"
        )
      } else if (mem_need > mem_free) {
        decision <- "comp"
        reason <- .glue(
          "cost: {as.integer(n_read %||% 1)} readers x ",
          "{round(.xla_client_mb)} MB XLA does not fit ",
          "{round(mem_free)} MB free headroom"
        )
      } else if (cost_fuse <= cost_mat) {
        decision <- "fuse"
        reason <- .glue(
          "cost: fuse {formatC(cost_fuse, format = 'f', digits = 3)}s <= ",
          "materialise {formatC(cost_mat, format = 'f', digits = 3)}s"
        )
      } else {
        decision <- "comp"
        reason <- .glue(
          "cost: materialise {formatC(cost_mat, format = 'f', digits = 3)}s < ",
          "fuse {formatC(cost_fuse, format = 'f', digits = 3)}s"
        )
      }
    }
    if (decision == "fuse") {
      # Per-task working-set estimate for the fused execution: the
      # window's activation cubes plus the raw read buffer and its
      # device copy. Rides the scheduler's compute in-flight byte
      # budget: a fused read IS compute, and admitting a fleet of
      # them by store bytes alone (fused outputs are tiny) stacked
      # N cold XLA ramps on top of whatever else holds the machine
      # (measured: crop=0 with the whole-AOI embedding staging resident).
      by_source[[.key(S@id)]] <- list(
        cid = C@id,
        ck = paste0(.stage_kernel_sig(graph, C), "@", C@device),
        fn = C@fn,
        dtype = graph_get(graph, C@input_nodes[[1L]])@grid@dtype,
        out_key = .key(C@exports[[1L]]),
        out_pad = C@out_pad,
        out_nb = .node_outer_nb(graph, C@exports[[1L]]),
        out_dtype = graph_get(graph, C@exports[[1L]])@grid@dtype,
        takes_ring = .takes_ring(graph, C),
        ws_mb = tl$ws_mb,
        tiles = tl$tiles
      )
      fused[[.key(C@id)]] <- TRUE
    }
    rows[[length(rows) + 1L]] <- data.frame(
      source = S@id,
      compute = C@id,
      bands = nb_src,
      flops_px = flops_px,
      move_mb = move_mb,
      cost_fuse_s = cost_fuse,
      cost_mat_s = cost_mat,
      decision = decision,
      tiles = tl$tiles,
      reason = reason
    )
  }
  list(
    by_source = by_source,
    fused = fused,
    table = if (length(rows)) {
      do.call(rbind, rows)
    } else {
      data.frame(
        source = integer(0),
        compute = integer(0),
        bands = integer(0),
        flops_px = numeric(0),
        move_mb = numeric(0),
        cost_fuse_s = numeric(0),
        cost_mat_s = numeric(0),
        decision = character(0),
        tiles = integer(0),
        reason = character(0)
      )
    }
  )
}

#' Explain the scheduler's placement decisions for a computation.
#'
#' Runs the placement pass over
#' the plan the same way `collect(distributed = TRUE)` would, and
#' returns its decision table: one row per fusable source -> compute
#' chain with the decision, the modelled costs (cost mode), and the
#' reason. Placement depends on runtime resources, so pool widths are
#' read from the live [garry_daemons()] pools when present; pass
#' `read` / `compute` to ask "what would the pass do with this
#' topology" without daemons running.
#'
#' @param x A `LazyRaster`, a named list of them (multi-export), or a
#'   `Plan`.
#' @param read,compute Pool widths to assume; default = the live pools
#'   (0 when none are running).
#' @return A data.frame with columns `source`, `compute`, `bands`,
#'   `flops_px`, `move_mb`, `cost_fuse_s`, `cost_mat_s`, `decision`,
#'   `tiles` (row tiles a fused kernel runs in), and `reason`; zero rows
#'   when no read feeds a compute stage.
#' @seealso [garry_options()], [garry_task_report()]
#' @export
garry_explain_placement <- function(x, read = NULL, compute = NULL) {
  p <- if (S7::S7_inherits(x, Plan)) x else plan_lazy(x)
  sc <- .placement_scan(p)
  n_read <- as.integer(read %||% .gd_n_compute("garry_read"))
  n_comp <- as.integer(compute %||% .comp_n())
  .plan_placement(
    p,
    sc$consumers_of,
    sc$warp_only,
    n_read = n_read,
    n_comp = n_comp,
    reader_threads = .garry_state$reader_threads,
    comp_threads = .garry_state$comp_threads,
    avail_mb = .garry_ram_avail_mb()
  )$table
}
