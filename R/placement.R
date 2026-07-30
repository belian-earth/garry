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
# v1 replaces decision site A of the design doc (the fuse predicate,
# formerly inline in the scheduler). Pool assignment for fetch-backed
# assembles (site B) stays in the scheduler: it depends on
# prepare_fetch's stateful index probing and is orthogonal to
# fuse-vs-materialise.
# ---------------------------------------------------------------------------

# Consumer index and warp-only mask, one pass, as the scheduler builds
# them. The scheduler keeps its own copy (it needs stage_kind and
# node_stage from the same sweep); this exists for callers that have
# only a Plan (the explain surface, tests).
.placement_scan <- function(plan) {
  stage_kind <- vapply(plan@stages, function(s) s@kind, character(1))
  consumers_of <- vector("list", length(plan@stages))
  for (t2 in plan@stages)
    for (i in t2@inputs)
      consumers_of[[i]] <- c(consumers_of[[i]], t2@id)
  warp_only <- vapply(plan@stages, function(s) {
    cons <- consumers_of[[s@id]]
    s@kind == "source_read" && length(cons) > 0L &&
      all(stage_kind[cons] == "warp") &&
      plan@sink != s@id &&
      !any(plan@sinks %in% s@members)
  }, logical(1))
  list(consumers_of = consumers_of, warp_only = warp_only)
}

# Correctness preconditions: which source -> compute chains CAN fuse.
# These are not policy: a violated precondition means fusion is wrong
# (a GPU stage would jit on a reader; a multi-consumer source's other
# consumers would find no stored window; multi-input/multi-export
# kernels do not fit the one-window-in, one-export-out fused task
# body). SINK stages are eligible since the scheduler's chunk lookup
# and streaming writers became fused-aware (chunk_of/sink_task_map):
# a fused sink's chunks stream from its source's read tasks. They are
# flagged `sinkful` so rules mode can keep the exact phase 12b
# behaviour (sinks stayed materialised). The dtype/halo raw-store
# gates stay in the scheduler: they are per-read-task store decisions,
# not placement.
.placement_candidates <- function(plan, consumers_of, warp_only) {
  out <- list()
  for (C in plan@stages) {
    if (C@kind != "compute") next
    if (!identical(C@device, "cpu")) next
    if (length(C@inputs) != 1L || length(C@exports) != 1L) next
    S <- plan@stages[[C@inputs[[1L]]]]
    if (S@kind != "source_read" || warp_only[[S@id]]) next
    if (length(unique(consumers_of[[S@id]])) != 1L) next
    out[[length(out) + 1L]] <- list(
      sid = S@id, cid = C@id,
      sinkful = C@id == plan@sink || any(plan@sinks %in% C@members))
  }
  out
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
# mode = "rules" reproduces the phase 12b behaviour exactly: fuse every
# candidate except multi-band (coalesced) sources, which keep their
# consumer on the warm pool. The runtime-resource arguments are unused
# in rules mode; they are the seam the cost mode (PR3) prices against.
.plan_placement <- function(plan, consumers_of, warp_only,
                            n_read = NULL, n_comp = NULL,
                            reader_threads = NULL, avail_mb = NULL,
                            mode = "rules") {
  if (!mode %in% c("rules", "cost"))
    .garry_error(sprintf("unknown placement mode: %s", mode),
                 "garry_placement_error")
  graph <- plan@graph
  cands <- .placement_candidates(plan, consumers_of, warp_only)
  by_source <- new.env(parent = emptyenv())
  fused <- new.env(parent = emptyenv())
  cores <- .garry_cores()$logical
  k <- reader_threads %||% NA_real_
  rows <- list()
  for (cc in cands) {
    S <- plan@stages[[cc$sid]]
    C <- plan@stages[[cc$cid]]
    nb_src <- length(graph_get(graph, S@members[[1L]])@band)
    flops_px <- cost_fuse <- cost_mat <- move_mb <- NA_real_
    if (identical(mode, "rules")) {
      # Phase 12b behaviour: sinks stay materialised, and a coalesced
      # multi-band source keeps its consumer on the COMPUTE pool
      # (fusing a wide kernel onto the lean readers would idle the
      # warm pool); single-band non-sink chains (mask cleanup) keep
      # the fusion win.
      decision <- if (cc$sinkful || nb_src > 1L) "comp" else "fuse"
      reason <- if (cc$sinkful)
        "rules: sink stage keeps its own tasks"
      else if (nb_src > 1L)
        "rules: multi-band source stays on the warm pool"
      else "rules: single-band source-fed chain fuses"
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
      move_mb <- px * .node_outer_nb(graph, S@members[[1L]]) * 4 / 2^20
      gf <- garry_opt("cost_gflops_core") * 1e9
      fl <- flops_px * px
      eff_fuse <- if (is.finite(k))
        min(cores, max(1, n_read %||% 1) * k) else cores
      cost_fuse <- fl / (gf * eff_fuse)
      # The fat pool's contended thread pools deliver a measured
      # fraction of machine-wide throughput (spike B); credit it
      # honestly or wide kernels stay materialised by a false margin.
      cost_mat <- 2 * move_mb / garry_opt("cost_shm_bw_mbs") +
        fl / (gf * cores * garry_opt("cost_comp_efficiency"))
      mem_need <- (n_read %||% 1) * garry_opt("cost_xla_client_mb")
      mem_free <- if (is.null(avail_mb) || is.na(avail_mb)) Inf else
        avail_mb * (1 - garry_opt("exec_ram_fraction"))
      # Fused kernels run at READ granularity — no chunking — so one
      # reader holds the whole window's input planes AND activation
      # cubes live. Price that against the per-reader budget; a chain
      # whose window working set does not fit materialises (the
      # chunked compute pool handles any size).
      win_px <- prod(pmin(as.numeric(S@chunks@chunk_dim),
                          as.numeric(S@grid@dims[c("x", "y")])))
      fuse_ws_mb <- win_px *
        .stage_fuse_act_bytes_px(graph, C@members, nb_src) / 2^20
      if (is.na(flops_px)) {
        decision <- "comp"
        reason <- "cost: unknown compute cost (scan / opaque custom body)"
      } else if (!is.finite(k) &&
                 flops_px > garry_opt("fuse_flops_max")) {
        decision <- "comp"
        reason <- sprintf(
          "cost: no reader thread cap and %.0f flops/px > fuse_flops_max %.0f (N uncapped XLA clients)",
          flops_px, garry_opt("fuse_flops_max"))
      } else if (fuse_ws_mb > garry_opt("fuse_reader_mb")) {
        decision <- "comp"
        reason <- sprintf(
          "cost: fused window working set %.0f MB exceeds fuse_reader_mb %.0f (window %.1f Mpx at read granularity)",
          fuse_ws_mb, garry_opt("fuse_reader_mb"), win_px / 1e6)
      } else if (mem_need > mem_free) {
        decision <- "comp"
        reason <- sprintf(
          "cost: %d readers x %.0f MB XLA does not fit %.0f MB free headroom",
          as.integer(n_read %||% 1), garry_opt("cost_xla_client_mb"),
          mem_free)
      } else if (cost_fuse <= cost_mat) {
        decision <- "fuse"
        reason <- sprintf("cost: fuse %.3fs <= materialise %.3fs",
                          cost_fuse, cost_mat)
      } else {
        decision <- "comp"
        reason <- sprintf("cost: materialise %.3fs < fuse %.3fs",
                          cost_mat, cost_fuse)
      }
    }
    if (decision == "fuse") {
      by_source[[.key(S@id)]] <- list(
        cid = C@id,
        ck = paste0(.stage_kernel_sig(graph, C), "@", C@device),
        fn = C@fn,
        dtype = graph_get(graph, C@input_nodes[[1L]])@grid@dtype,
        out_key = .key(C@exports[[1L]]),
        out_pad = C@out_pad,
        out_nb = .node_outer_nb(graph, C@exports[[1L]]))
      fused[[.key(C@id)]] <- TRUE
    }
    rows[[length(rows) + 1L]] <- data.frame(
      source = S@id, compute = C@id, bands = nb_src,
      flops_px = flops_px, move_mb = move_mb,
      cost_fuse_s = cost_fuse, cost_mat_s = cost_mat,
      decision = decision, reason = reason)
  }
  list(by_source = by_source, fused = fused,
       table = if (length(rows)) do.call(rbind, rows) else
         data.frame(source = integer(0), compute = integer(0),
                    bands = integer(0), flops_px = numeric(0),
                    move_mb = numeric(0), cost_fuse_s = numeric(0),
                    cost_mat_s = numeric(0), decision = character(0),
                    reason = character(0)))
}

#' Explain the scheduler's placement decisions for a computation.
#'
#' Runs the placement pass (see `design/placement-cost-pass.md`) over
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
#' @param mode `"rules"` or `"cost"`; default `garry_opt("placement")`.
#' @return A data.frame with columns `source`, `compute`, `bands`,
#'   `flops_px`, `move_mb`, `cost_fuse_s`, `cost_mat_s`, `decision`,
#'   `reason`.
#' @export
garry_explain_placement <- function(x, read = NULL, compute = NULL,
                                    mode = garry_opt("placement")) {
  p <- if (S7::S7_inherits(x, Plan)) x else plan_lazy(x)
  sc <- .placement_scan(p)
  n_read <- as.integer(read %||%
    tryCatch(.gd_n_compute("garry_read"), error = function(e) 0L))
  n_comp <- as.integer(compute %||%
    tryCatch(.gd_n_compute("garry_compute"), error = function(e) 0L))
  .plan_placement(p, sc$consumers_of, sc$warp_only,
                  n_read = n_read, n_comp = n_comp,
                  reader_threads = .garry_state$reader_threads,
                  avail_mb = .garry_ram_avail_mb(),
                  mode = mode)$table
}
