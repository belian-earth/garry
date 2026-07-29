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
# Lifted verbatim from the phase 12b predicate. These are not policy:
# a violated precondition means fusion is wrong (the sink's chunks
# must exist under the sink stage's own task keys; a GPU stage would
# jit on a reader; a multi-consumer source's other consumers would
# find no stored window; multi-input/multi-export kernels do not fit
# the one-window-in, one-export-out fused task body). The dtype/halo
# raw-store gates stay in the scheduler: they are per-read-task store
# decisions, not placement.
.placement_candidates <- function(plan, consumers_of, warp_only) {
  out <- list()
  for (C in plan@stages) {
    if (C@kind != "compute" || C@id == plan@sink) next
    # Multi-export: a stage carrying ANY requested sink must keep its
    # own chunk tasks — streamed writes and host retrieval both key on
    # them. Fusing such a stage stored its output under the READ task
    # keys and the sink came back empty (found 2026-07-29; the phase
    # 12b predicate only excluded the primary sink).
    if (any(plan@sinks %in% C@members)) next
    if (!identical(C@device, "cpu")) next
    if (length(C@inputs) != 1L || length(C@exports) != 1L) next
    S <- plan@stages[[C@inputs[[1L]]]]
    if (S@kind != "source_read" || warp_only[[S@id]]) next
    if (length(unique(consumers_of[[S@id]])) != 1L) next
    out[[length(out) + 1L]] <- list(sid = S@id, cid = C@id)
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
  if (!identical(mode, "rules"))
    .garry_error(sprintf("unknown placement mode: %s", mode),
                 "garry_placement_error")
  graph <- plan@graph
  cands <- .placement_candidates(plan, consumers_of, warp_only)
  by_source <- new.env(parent = emptyenv())
  fused <- new.env(parent = emptyenv())
  rows <- list()
  for (cc in cands) {
    S <- plan@stages[[cc$sid]]
    C <- plan@stages[[cc$cid]]
    nb_src <- length(graph_get(graph, S@members[[1L]])@band)
    # A coalesced multi-band source keeps its consumer on the COMPUTE
    # pool: fusing a wide kernel (e.g. a 145-band MLP reduce) into
    # the read task would move the plan's whole compute onto the
    # lean read daemons and idle the warm pool. Single-band chains
    # (mask cleanup) keep the fusion win.
    decision <- if (nb_src > 1L) "comp" else "fuse"
    reason <- if (nb_src > 1L)
      "rules: multi-band source stays on the warm pool"
    else "rules: single-band source-fed chain fuses"
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
      decision = decision, reason = reason)
  }
  list(by_source = by_source, fused = fused,
       table = if (length(rows)) do.call(rbind, rows) else
         data.frame(source = integer(0), compute = integer(0),
                    bands = integer(0), decision = character(0),
                    reason = character(0)))
}
