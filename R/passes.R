#' @include plan.R node.R generics.R ops.R options.R
#' @importFrom rlang %||%
#' @keywords internal
NULL

# ---------------------------------------------------------------------------
# Planner passes (decisions D10-D12). Run by collect(); pure functions of
# the IR graph. Two phases:
#   1. assignment  — every reachable node lands in a stage (fusion,
#                    reduce decomposition, warp barriers);
#   2. finalise    — per-stage exports, composed closures, halo, focal
#                    placement check, chunking, export as Plan.
#
# Stage output contract: every stage closure returns a NAMED LIST keyed
# by node id (its "exports": members consumed by other stages, plus the
# stage tail). Consumers fetch by node id, so fusion decisions can never
# orphan an externally-referenced member.
# ---------------------------------------------------------------------------

# Structured, cli-formatted garry error. `msg` is taken literally (interpolated
# once), so caller-built strings with stray braces are safe; the condition
# carries `class` plus "garry_error" and points at the calling function.
.garry_error <- function(msg, class, call = rlang::caller_env()) {
  cli::cli_abort("{msg}", class = c(class, "garry_error"), call = call)
}

# -- Chunk array layout (D13 + D7) --------------------------------------------

# 2D chunks are [y, x] matrices; outer dims stack before y in grid-dims
# order, e.g. (t, y, x).
.dim_layout <- function(dim_names) {
  c(setdiff(dim_names, c("x", "y")), "y", "x")
}

.dim_margins <- function(dim_names, over) {
  match(over, .dim_layout(dim_names))
}

# -- Node evaluation (shared by oracle tests and the Phase 5 executor) --------

.apply_reduce <- function(op, x, margins, nan_rm) {
  switch(op,
    sum    = g_sum(x, dims = margins, nan_rm = nan_rm),
    mean   = g_mean(x, dims = margins, nan_rm = nan_rm),
    min    = g_min(x, dims = margins, nan_rm = nan_rm),
    max    = g_max(x, dims = margins, nan_rm = nan_rm),
    median = g_median(x, dims = margins, nan_rm = nan_rm),
    count  = g_count(x, dims = margins),
    .garry_error(paste0("reduction op not executable: ", op),
                 "garry_reduce_unsupported_error")
  )
}

# Evaluate one IR node given its parent chunk values. Focal members
# consume `radius` cells of padding via shifted slices (halo contract in
# plan.R), so array shapes track the remaining pad implicitly.
.eval_node <- function(node, pv, parent_dim_names) {
  if (S7::S7_inherits(node, MapNode)) {
    do.call(node@fn, pv)
  } else if (S7::S7_inherits(node, FocalNode)) {
    x <- pv[[1L]]
    r <- node@radius
    # window from the LAST two (spatial) dims: focal ops vectorise over
    # leading dims (a (band, y, x) cube filters every channel at once)
    sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
    nr <- sh[[length(sh) - 1L]] - 2L * r
    nc <- sh[[length(sh)]] - 2L * r
    offsets <- expand.grid(dx = -r:r, dy = -r:r)   # row-major over (dy, dx)
    shifts <- lapply(seq_len(nrow(offsets)), function(i) {
      g_shift_slice(x, offsets$dy[i], offsets$dx[i], nr, nc, r)
    })
    if (length(node@weights) > 0L) {
      Reduce(`+`, Map(function(s2, w) s2 * w, shifts,
                      as.list(node@weights)))
    } else {
      node@fn(shifts)
    }
  } else if (S7::S7_inherits(node, StackNode)) {
    g_stack(pv)
  } else if (S7::S7_inherits(node, ReduceNode)) {
    margins <- .dim_margins(parent_dim_names, node@over)
    if (length(node@fn)) node@fn[[1L]](pv[[1L]], margins)   # custom anvl reducer
    else .apply_reduce(node@op, pv[[1L]], margins, node@nan_rm)
  } else if (S7::S7_inherits(node, ScanNode)) {
    # Body contract: fn(xs, margin) over the LIST of parent values; the
    # scanned axis survives, so the output keeps the parent's shape.
    node@fn[[1L]](pv, .dim_margins(parent_dim_names, node@over))
  } else {
    .garry_error(paste0("node class not executable in a compute stage: ",
                        class(node)[[1L]]), "garry_plan_error")
  }
}

# Trim `d` cells of padding from every side (centered slice) of the
# LAST two (spatial) dims; leading dims (t/band cubes) pass in full.
.trim_to_pad <- function(x, d) {
  d <- as.integer(d)
  if (d == 0L) return(x)
  sh <- if (.g_traced(x)) .g_shape(x) else dim(x)
  if (is.null(sh)) sh <- length(x)
  nr <- sh[[length(sh) - 1L]] - 2L * d
  nc <- sh[[length(sh)]] - 2L * d
  if (.g_traced(x) || length(sh) == 2L)
    return(g_shift_slice(x, 0L, 0L, nr, nc, d))
  # untraced (outer, y, x) cube
  idx <- c(rep(list(quote(expr = )), length(sh) - 2L),
           list((d + 1L):(d + nr), (d + 1L):(d + nc)))
  do.call(`[`, c(list(x), idx, list(drop = FALSE)))
}

# Rebind a user node fn onto a minimal environment holding only its
# free variables (found via codetools), parented on globalenv(). Node
# fns otherwise capture their construction environment, which typically
# references LazyRasters and through them the ENTIRE graph: one such
# closure serialized at ~117 MB in a 500-node plan, and every mirai
# task ships its stage closure, so daemons accumulated a full graph
# copy per stage (machine OOM). g_* calls resolve through globalenv()
# (garry attached), exactly as on daemons today.
.slim_fn <- function(fn) {
  if (!is.function(fn) || is.primitive(fn)) return(fn)
  env <- environment(fn)
  if (is.null(env) || identical(env, globalenv()) ||
      isNamespace(env)) return(fn)
  g <- codetools::findGlobals(fn, merge = FALSE)
  # Reparent onto the closure's terminal environment: a namespace when
  # the chain ends in one (serialises by reference and keeps unexported
  # helpers resolvable on daemons and in sessions where the package is
  # not attached -- e.g. garry's own factory bodies like bilateral_focal),
  # else globalenv as before.
  terminal <- env
  while (!identical(terminal, globalenv()) &&
         !identical(terminal, emptyenv()) && !isNamespace(terminal)) {
    terminal <- parent.env(terminal)
  }
  if (!isNamespace(terminal)) terminal <- globalenv()
  e <- new.env(parent = terminal)
  for (v in unique(c(g$variables, g$functions))) {
    # Copy only bindings that live BELOW globalenv/namespace boundaries
    # (true captures); package and global bindings resolve at run time.
    scope <- env
    while (!identical(scope, globalenv()) && !identical(scope, emptyenv()) &&
           !isNamespace(scope)) {
      if (exists(v, envir = scope, inherits = FALSE)) {
        assign(v, get(v, envir = scope), envir = e)
        break
      }
      scope <- parent.env(scope)
    }
  }
  environment(fn) <- e
  fn
}

# Composed closure for a compute stage: runs members in ascending (topo)
# order, returns the named list of exports. Each value carries a
# remaining-pad count: inputs start at `halo + out_pad` (D22), focal
# members consume `radius`, and map members that join branches with
# different pads trim the larger to the common minimum (the halo
# contract in plan.R generalised to DAGs). `.stage_export_pads` is the
# static mirror of this walk; keep them in lockstep.
#
# The closure captures per-member SPECS extracted from the graph, never
# the graph itself: stage closures are serialized to daemons per task,
# and a graph capture multiplies the whole plan into every payload (see
# .slim_fn). rm() below keeps the closure environment minimal.
.compose_stage_fn <- function(graph, members, input_nodes, exports, halo,
                              out_pad = 0L) {
  specs <- lapply(members, function(id) {
    node <- graph_get(graph, id)
    if (S7::S7_inherits(node, MapNode) || S7::S7_inherits(node, FocalNode))
      node@fn <- .slim_fn(node@fn)
    # Custom reducer / scan bodies are NOT slimmed: factory-built bodies
    # (band_project, kalman_llt) reference garry internals through their
    # namespace-parented env, which serializes compactly by reference;
    # slimming would cut that resolution path on daemons.
    list(id = id, node = node,
         pdims = names(graph_get(graph, node@parents[[1L]])@grid@dims))
  })
  in_pad <- as.integer(halo + out_pad)
  force(input_nodes); force(exports)
  rm(graph, members, halo, out_pad)
  function(inputs) {
    vals <- new.env(parent = emptyenv())
    pads <- new.env(parent = emptyenv())
    for (i in seq_along(input_nodes)) {
      k <- .key(input_nodes[[i]])
      assign(k, inputs[[i]], envir = vals)
      assign(k, in_pad, envir = pads)
    }
    for (sp in specs) {
      node <- sp$node
      pv <- lapply(node@parents, function(p) get(.key(p), envir = vals))
      pp <- vapply(node@parents, function(p) get(.key(p), envir = pads),
                   integer(1))
      if (S7::S7_inherits(node, FocalNode)) {
        out_pad <- pp[[1L]] - node@radius
      } else {
        out_pad <- min(pp)
        pv <- Map(function(v, d) .trim_to_pad(v, d - out_pad), pv,
                  as.list(pp))
      }
      assign(.key(sp$id),
             .eval_node(node, pv, parent_dim_names = sp$pdims),
             envir = vals)
      assign(.key(sp$id), as.integer(out_pad), envir = pads)
    }
    stats::setNames(
      lapply(exports, function(e) get(.key(e), envir = vals)),
      vapply(exports, .key, character(1)))
  }
}

# Static mirror of .compose_stage_fn's pad walk (D22): the padding each
# export value carries at run time, computed at plan time so consumers
# and sink writers know how much to trim without inspecting values.
.stage_export_pads <- function(graph, members, input_nodes, exports,
                               halo, out_pad) {
  pads <- new.env(parent = emptyenv())
  for (i in input_nodes)
    assign(.key(i), as.integer(halo + out_pad), envir = pads)
  for (id in members) {
    node <- graph_get(graph, id)
    pp <- vapply(node@parents, function(p) get(.key(p), envir = pads),
                 integer(1))
    out <- if (S7::S7_inherits(node, FocalNode)) pp[[1L]] - node@radius
           else min(pp)
    assign(.key(id), as.integer(out), envir = pads)
  }
  vapply(exports, function(e) get(.key(e), envir = pads), integer(1))
}

# Pass-through closure for source_read / warp stages (executor supplies
# the window array as the single input).
.passthrough_fn <- function(node_id) {
  force(node_id)
  function(inputs) stats::setNames(inputs[1L], .key(node_id))
}

# -- Reduce decomposition (D12) -----------------------------------------------

.algebraic_ops <- c("sum", "mean", "min", "max", "count")

.reduce_partial_fn <- function(node, dim_names) {
  force(node); force(dim_names)
  margins <- .dim_margins(dim_names, node@over)
  op <- node@op
  nan_rm <- node@nan_rm
  key <- .key(node@id)
  function(inputs) {
    x <- inputs[[1L]]
    part <- switch(op,
      sum   = list(sum = g_sum(x, margins, nan_rm)),
      count = list(count = g_count(x, margins)),
      min   = list(min = g_min(x, margins, nan_rm)),
      max   = list(max = g_max(x, margins, nan_rm)),
      mean  = list(sum = g_sum(x, margins, nan_rm),
                   count = g_count(x, margins))
    )
    stats::setNames(list(part), key)
  }
}

.reduce_combine_fn <- function(node) {
  force(node)
  op <- node@op
  key <- .key(node@id)
  function(partials) {
    get_all <- function(field) lapply(partials, `[[`, field)
    out <- switch(op,
      sum   = Reduce(`+`, get_all("sum")),
      count = Reduce(`+`, get_all("count")),
      min   = Reduce(pmin, get_all("min")),
      max   = Reduce(pmax, get_all("max")),
      mean  = Reduce(`+`, get_all("sum")) / Reduce(`+`, get_all("count"))
    )
    stats::setNames(list(out), key)
  }
}

# -- Stage-merge pass (Phase 9) ------------------------------------------------

# Fuse compute stages into their consumers, to fixpoint: a compute
# stage consumed by EXACTLY ONE other compute stage folds its members
# into that consumer, so the whole chain runs as one XLA program and
# the producer's chunk-store round-trip disappears (e.g. per-slice
# mask maps fuse into the stack+median stage that consumes them).
#
# Guards (v1):
#   - single consumer, both stages "compute" (multi-consumer producers
#     stay materialised: fusing them would duplicate work);
#   - spatially identical grids, so chunk tables stay aligned (the
#     executors match input chunks by index);
#   - the merged stage must need no halo: focal members keep their own
#     narrow stage so the halo lands on the fewest reads (a cost
#     choice since D22 made padded compute boundaries executable);
#   - fusion never crosses a reduction into a join: a stage whose
#     consumed root is a ReduceNode does not fold into a consumer with
#     other inputs. Folding it would widen every chunk's dependency
#     frontier to the sibling subtrees' sources (e.g. three per-band
#     medians joined by a band stack would all wait for ALL bands'
#     reads), while keeping the boundary costs only the store
#     round-trip of the reduced - smallest possible - output.
.merge_stages <- function(protos, graph, halos = NULL) {
  repeat {
    did_merge <- FALSE
    # inputs -> consumer-stage index for this pass. Merges keep it a
    # SUPERSET of the truth (q inherits p's inputs below), so every
    # candidate is re-verified against the live protos before use;
    # this replaces an O(stages) scan per candidate per pass.
    cons <- vector("list", length(protos))
    for (j in seq_along(protos)) {
      q <- protos[[j]]
      if (is.null(q)) next
      for (inp in q$inputs) cons[[inp]] <- c(cons[[inp]], j)
    }
    for (i in seq_along(protos)) {
      p <- protos[[i]]
      if (is.null(p) || p$kind != "compute") next
      cids <- unique(cons[[i]])
      cids <- cids[vapply(cids, function(j) {
        q <- protos[[j]]
        !is.null(q) && p$id %in% q$inputs
      }, logical(1))]
      if (length(cids) != 1L) next
      q <- protos[[cids]]
      if (q$kind != "compute") next
      if (!.spatial_equal(p$grid, q$grid)) next
      if (length(q$inputs) > 1L) {
        # The barrier is the producer CONTAINING a reduction/scan, not
        # just producing one at the consumed boundary: a map after the
        # reduce would otherwise defeat the guard (the consumed root is
        # the MapNode) and fold the whole reduce subtree into the join,
        # widening every chunk's dependency frontier to the sibling
        # subtrees' sources (measured: a per-year post-reduce map
        # collapsed a 24-stage predict plan into 2 mega-stages and
        # inflated the task count 18x through the sizing passes).
        if (any(vapply(p$members, function(m) {
          n <- graph_get(graph, m)
          S7::S7_inherits(n, ReduceNode) || S7::S7_inherits(n, ScanNode)
        }, logical(1)))) next
      }
      members <- sort(unique(c(p$members, q$members)))
      input_nodes <- setdiff(unique(c(p$input_nodes, q$input_nodes)),
                             members)
      if (.stage_halo(graph, members, input_nodes, halos) > 0L) next
      protos[[q$id]]$members <- members
      protos[[q$id]]$input_nodes <- input_nodes
      protos[[q$id]]$inputs <-
        setdiff(unique(c(p$inputs, q$inputs)), p$id)
      protos[p$id] <- list(NULL)
      for (inp in p$inputs) cons[[inp]] <- c(cons[[inp]], q$id)
      did_merge <- TRUE
    }
    if (!did_merge) break
  }
  # Compact dead slots and renumber ids (inputs remapped to match).
  live <- which(!vapply(protos, is.null, logical(1)))
  remap <- integer(length(protos))
  remap[live] <- seq_along(live)
  lapply(seq_along(live), function(j) {
    s <- protos[[live[[j]]]]
    s$id <- j
    s$inputs <- sort(unique(remap[s$inputs]))
    s
  })
}

# -- Band-stack collapse (multi-band read coalescing) --------------------------
#
# A StackNode whose parents are all single-band SourceNodes addressing
# the SAME file (path, open options, nodata, resampling, spatially
# identical 2-D grids) is replaced IN PLACE by one multi-band
# SourceNode carrying the stack's node id and grid. Consumers are
# untouched: stage exports key on node ids, and the read value arrives
# as the same (band, y, x) cube g_stack would have built. The win is
# structural: one read task per (file, window) instead of one per
# (band, window) — per-band reads of an N-band pixel-interleaved file
# decompress ~N x the window bytes, and with the read budget the task
# count scales as bands^2 (n_src = bands x files and windows shrink by
# bands), where the coalesced plan reads the same bytes in one task
# and one store region.
#
# Skips: stacks that are themselves requested sinks (sink retrieval
# from a coarse split read stage is not wired); stacks consumed by a
# WarpNode (the warp path takes scalar bands — warping a stack was an
# error before this pass and stays one); parents with outer dims or
# multi-band parents (a stack of stacks keeps its compute shape).
# Per-band sources still referenced elsewhere stay reachable and keep
# their own read stages.
.collapse_band_stacks <- function(graph, sink_ids) {
  if (!isTRUE(garry_opt("read_coalesce"))) return(invisible(graph))
  ids <- sort(unique(unlist(lapply(unique(sink_ids), function(i)
    .reachable(graph, i)))))
  consumers <- new.env(parent = emptyenv())
  for (id in ids) {
    for (p in .node_parents(graph_get(graph, id)))
      consumers[[.key(p)]] <- c(consumers[[.key(p)]], id)
  }
  for (id in ids) {
    st <- graph_get(graph, id)
    if (!S7::S7_inherits(st, StackNode)) next
    if (id %in% sink_ids) next
    parents <- .node_parents(st)
    if (length(parents) < 2L) next
    ps <- lapply(parents, function(p) graph_get(graph, p))
    if (!all(vapply(ps, function(n)
      S7::S7_inherits(n, SourceNode), logical(1)))) next
    if (!all(vapply(ps, function(n) length(n@band) == 1L, logical(1)))) next
    if (any(vapply(ps, function(n)
      length(setdiff(names(.node_grid(n)@dims), c("x", "y"))) > 0L,
      logical(1)))) next
    p1 <- ps[[1L]]
    same <- vapply(ps[-1L], function(n) {
      identical(n@path, p1@path) &&
        identical(n@open_options, p1@open_options) &&
        identical(n@nodata, p1@nodata) &&
        identical(n@resampling, p1@resampling) &&
        identical(.node_grid(n)@dtype, .node_grid(p1)@dtype) &&
        grid_equal(.node_grid(n), .node_grid(p1))
    }, logical(1))
    if (!all(same)) next
    if (any(vapply(consumers[[.key(id)]], function(c2)
      S7::S7_inherits(graph_get(graph, c2), WarpNode), logical(1)))) next
    graph_replace(graph, id, SourceNode(
      id = st@id, parents = integer(0), grid = .node_grid(st),
      path = p1@path,
      band = vapply(ps, function(n) n@band, integer(1)),
      nodata = p1@nodata,
      block_dim = p1@block_dim,
      open_options = p1@open_options,
      resampling = p1@resampling))
  }
  invisible(graph)
}

# -- The planner ---------------------------------------------------------------

#' Plan a LazyRaster: run all planner passes and export a Plan.
#'
#' @param x A `LazyRaster`.
#' @return A `Plan`.
#' @export
plan_lazy <- function(x) {
  # Multi-export: a NAMED list of LazyRasters plans as ONE graph with one
  # execution and several sinks (design/multi-export-collect.md).
  if (is.list(x) && !S7::S7_inherits(x, LazyRaster)) {
    stopifnot(length(x) >= 1L, !is.null(names(x)), all(nzchar(names(x))))
    graph <- x[[1L]]@graph
    sink_ids <- vapply(seq_along(x), function(i) {
      lr <- x[[i]]
      if (!S7::S7_inherits(lr, LazyRaster))
        cli::cli_abort("sink {i} must be a {.cls LazyRaster}")
      if (identical(graph@nodes, lr@graph@nodes)) lr@node_id
      else graph_import(graph, lr@graph, lr@node_id)
    }, integer(1))
    names(sink_ids) <- names(x)
    # The primary sink must be the id IN THE MERGED GRAPH: a sink built
    # on its own graph is renumbered by graph_import above, so
    # `x[[k]]@node_id` is a stale id from the source graph and matches a
    # stage only by coincidence (when it does not, the sink lookup in
    # .plan_lazy_impl finds nothing and Plan() errors).
    return(.plan_lazy_impl(graph, unname(sink_ids[[length(sink_ids)]]),
                           sink_ids))
  }
  stopifnot(S7::S7_inherits(x, LazyRaster))
  .plan_lazy_impl(x@graph, x@node_id,
                  stats::setNames(x@node_id, "sink"))
}

.plan_lazy_impl <- function(graph, primary_id, sink_ids) {
  # Multi-band read coalescing rewrites same-file band stacks into
  # multi-band SourceNodes BEFORE staging (in place: the rewrite is
  # semantics-preserving and idempotent, so a shared user graph stays
  # valid for later collects).
  .collapse_band_stacks(graph, unname(sink_ids))
  ids <- sort(unique(unlist(lapply(unique(sink_ids), function(i)
    .reachable(graph, i)))))

  # required_halo is static per node; computed once here, threaded
  # through the merge pass and finalise (S7 dispatch per call adds up
  # over the merge pass's repeated .stage_halo calls).
  halos <- stats::setNames(
    vapply(ids, function(i) required_halo(graph_get(graph, i)), integer(1)),
    as.character(ids))

  # ---- Phase A: assign nodes to proto-stages --------------------------------
  protos <- list()                              # id -> mutable list
  node_stage <- new.env(parent = emptyenv())    # node id -> stage id
  # Stages already consumed. An env, not a vector: the `%in%` form
  # re-scanned an ever-growing vector once per node (O(nodes^2) — a
  # per-band pre-stack map arm tripled plan time at 2.5k sources).
  closed <- new.env(parent = emptyenv())
  is_closed <- function(sid) isTRUE(closed[[.key(sid)]])
  close_stages <- function(sids) {
    for (s2 in sids) closed[[.key(s2)]] <- TRUE
  }
  # Open compute stages indexed by their (sorted, unique) input-stage
  # set, replacing the linear Find over all protos in the join branch
  # below. Entries go stale when fusion widens a stage's inputs; the
  # lookup re-verifies each candidate against its live key.
  open_compute <- new.env(parent = emptyenv())
  inputs_key <- function(sids)
    paste(sort(unique(as.integer(sids))), collapse = ",")
  reg_open <- function(sid, inputs) {
    k <- inputs_key(inputs)
    open_compute[[k]] <- c(open_compute[[k]], sid)
  }

  new_proto <- function(kind, members, grid, inputs, input_nodes,
                        has_focal = FALSE) {
    id <- length(protos) + 1L
    protos[[id]] <<- list(id = id, kind = kind, members = members,
                          grid = grid, inputs = unique(inputs),
                          input_nodes = input_nodes, halo = 0L,
                          fn = NULL, has_focal = has_focal)
    close_stages(inputs)
    if (kind == "compute") reg_open(id, inputs)
    id
  }

  for (id in ids) {
    node <- graph_get(graph, id)

    if (S7::S7_inherits(node, SourceNode)) {
      node_stage[[.key(id)]] <-
        new_proto("source_read", id, .node_grid(node), integer(0), id)

    } else if (S7::S7_inherits(node, WarpNode)) {
      pin <- .node_parents(node)[[1L]]
      if (!S7::S7_inherits(graph_get(graph, pin), SourceNode))
        .garry_error(paste0(
          "warping a computed raster is not supported in v1: align() ",
          "sources before computing on them, or materialise to disk ",
          "first (collect(x, path = ...))."),
          "garry_warp_unsupported_error")
      node_stage[[.key(id)]] <-
        new_proto("warp", id, node@target_grid,
                  node_stage[[.key(pin)]], pin)

    } else if (S7::S7_inherits(node, ReduceNode) &&
               any(node@over %in% c("x", "y"))) {
      if (!all(c("x", "y") %in% node@over))
        .garry_error(paste0(
          "reducing over a single spatial axis is not supported in v1; ",
          "reduce over c(\"x\", \"y\")"),
          "garry_reduce_unsupported_error")
      if (!node@op %in% .algebraic_ops)
        .garry_error(paste0(
          "op \"", node@op, "\" cannot be distributed over spatial ",
          "chunks; algebraic ops (", paste(.algebraic_ops, collapse = ", "),
          ") only (D12). median/quantile remain available over t/band."),
          "garry_reduce_unsupported_error")
      pin <- .node_parents(node)[[1L]]
      # Partial stage chunks over the INPUT grid (it runs per input
      # chunk); only the combine stage lives on the reduced grid.
      part <- new_proto("reduce_partial", id,
                        .node_grid(graph_get(graph, pin)),
                        node_stage[[.key(pin)]], pin)
      node_stage[[.key(id)]] <-
        new_proto("reduce_combine", id, .node_grid(node), part, id)

    } else {
      # Fusable: MapNode, FocalNode, chunk-local Reduce over t/band.
      parents <- .node_parents(node)
      parent_sids <- unique(vapply(parents,
                                   function(p) node_stage[[.key(p)]],
                                   integer(1)))
      compute_sids <- parent_sids[vapply(parent_sids, function(s)
        protos[[s]]$kind == "compute" && !is_closed(s), logical(1))]

      if (length(compute_sids) == 1L) {
        sid <- compute_sids
        ext <- parents[!parents %in% protos[[sid]]$members &
                       !parents %in% protos[[sid]]$input_nodes]
        if (protos[[sid]]$has_focal && length(ext) > 0L) {
          # Halo stages stay NARROW: fusing a node that brings new
          # external inputs into a focal-bearing stage would put the
          # stage's halo on every added source's reads (measured:
          # band reads inheriting the mask chain's halo-7 windows)
          # and widen its export set. Cut the boundary instead; D22
          # pad propagation keeps it executable (the producer emits
          # a recomputed ring), so this is a cost choice, not a
          # placement restriction. This is also what keeps source-fed
          # kernel chains single-input/single-export for
          # compute-on-read.
          # Weighted (differentiable) kernels are EXEMPT — see the
          # has_focal setters: the v1 gradient tape requires the
          # whole loss pipeline in one compute stage.
          node_stage[[.key(id)]] <-
            new_proto("compute", id, .node_grid(node),
                      vapply(parents, function(p) node_stage[[.key(p)]],
                             integer(1)),
                      parents,
                      has_focal = S7::S7_inherits(node, FocalNode) && length(node@weights) == 0L)
          next
        }
        # Fuse into the single open compute ancestor.
        protos[[sid]]$members <- c(protos[[sid]]$members, id)
        if (S7::S7_inherits(node, FocalNode) && length(node@weights) == 0L)
          protos[[sid]]$has_focal <- TRUE
        if (length(ext) > 0L) {
          ext_sids <- vapply(ext, function(p) node_stage[[.key(p)]],
                             integer(1))
          protos[[sid]]$input_nodes <- c(protos[[sid]]$input_nodes, ext)
          protos[[sid]]$inputs <- unique(c(protos[[sid]]$inputs, ext_sids))
          close_stages(ext_sids)
          reg_open(sid, protos[[sid]]$inputs)   # key changed; old entry stale
        }
        protos[[sid]]$grid <- .node_grid(node)
        node_stage[[.key(id)]] <- sid
      } else if (length(compute_sids) == 0L) {
        # Join an open compute stage with the identical input set (keeps
        # diamonds in one stage), else start a new one. Candidates come
        # from the inputs-keyed index (earliest-created first, matching
        # the previous linear Find); stale entries (inputs widened by
        # fusion since registration) fail the live-key check.
        pk <- inputs_key(parent_sids)
        joinable <- NULL
        for (cand in open_compute[[pk]]) {
          s2 <- protos[[cand]]
          if (!is_closed(cand) && identical(inputs_key(s2$inputs), pk)) {
            joinable <- s2
            break
          }
        }
        if (is.null(joinable)) {
          node_stage[[.key(id)]] <-
            new_proto("compute", id, .node_grid(node), parent_sids,
                      parents,
                      has_focal = S7::S7_inherits(node, FocalNode) && length(node@weights) == 0L)
        } else {
          sid <- joinable$id
          protos[[sid]]$members <- c(protos[[sid]]$members, id)
          if (S7::S7_inherits(node, FocalNode) && length(node@weights) == 0L)
            protos[[sid]]$has_focal <- TRUE
          protos[[sid]]$input_nodes <-
            unique(c(protos[[sid]]$input_nodes, parents))
          protos[[sid]]$grid <- .node_grid(node)
          node_stage[[.key(id)]] <- sid
        }
      } else {
        # Distinct compute ancestries meet: consume both, materialised.
        node_stage[[.key(id)]] <-
          new_proto("compute", id, .node_grid(node), parent_sids,
                    parents,
                    has_focal = S7::S7_inherits(node, FocalNode) && length(node@weights) == 0L)
      }
    }
  }

  # ---- Stage-merge pass -------------------------------------------------------
  protos <- .merge_stages(protos, graph, halos)

  # ---- Phase B: finalise -----------------------------------------------------

  # One-pass indexes over the (merged, renumbered) protos, replacing
  # three O(stages^2) scans below: proto id -> consuming proto ids, and
  # node id -> proto ids referencing it as an input. At ~2.5k stages
  # the per-stage Filter/unlist forms cost ~7 s of a 7.5 s plan.
  cons_idx <- vector("list", length(protos))
  ref_stages <- new.env(parent = emptyenv())
  for (j in seq_along(protos)) {
    for (inp in protos[[j]]$inputs)
      cons_idx[[inp]] <- c(cons_idx[[inp]], j)
    for (nid in protos[[j]]$input_nodes) {
      k <- .key(nid)
      ref_stages[[k]] <- c(ref_stages[[k]], j)
    }
  }

  # Exports: members referenced by other stages' input_nodes, plus tail.
  for (i in seq_along(protos)) {
    s <- protos[[i]]
    s$members <- sort(s$members)
    tail_id <- s$members[[length(s$members)]]
    ext <- s$members[vapply(s$members, function(m) {
      r <- ref_stages[[.key(m)]]
      !is.null(r) && any(r != i)
    }, logical(1))]
    # Every requested sink node must leave its stage (multi-export).
    s$exports <- sort(unique(c(ext, tail_id,
                               intersect(s$members, unname(sink_ids)))))
    protos[[i]] <- s
  }

  for (i in seq_along(protos)) {
    if (protos[[i]]$kind == "compute")
      protos[[i]]$halo <- .stage_halo(graph, protos[[i]]$members,
                                      protos[[i]]$input_nodes, halos)
    protos[[i]]$out_pad <- 0L
  }

  # D22: propagate output padding backwards over the stage DAG. A stage
  # whose consumer needs `halo + out_pad` cells computes its chunks
  # enlarged by that ring (recompute, not exchange:
  # design/halo-propagation.md). Fixpoint iteration — stage ids are
  # creation-ordered, not topological, and the DAG is small.
  repeat {
    changed <- FALSE
    for (i in seq_along(protos)) {
      if (protos[[i]]$kind %in% c("source_read", "warp")) next
      cons <- protos[cons_idx[[i]]]
      need <- if (length(cons) == 0L) 0L else
        max(vapply(cons, function(s) as.integer(s$halo + s$out_pad),
                   integer(1)))
      if (need != protos[[i]]$out_pad) {
        protos[[i]]$out_pad <- need
        changed <- TRUE
      }
    }
    if (!changed) break
  }
  for (s in protos) {
    if (s$kind == "reduce_combine" && s$out_pad > 0L)
      .garry_error(paste0(
        "a focal window cannot follow a spatial reduction: the reduced ",
        "value has no neighbourhood to recompute (D22). Materialise ",
        "first or restructure the pipeline."),
        "garry_focal_placement_error")
  }

  for (i in seq_along(protos)) {
    s <- protos[[i]]
    if (s$kind == "compute") {
      s$fn <- .compose_stage_fn(graph, s$members, s$input_nodes,
                                s$exports, s$halo, s$out_pad)
      s$export_pads <- .stage_export_pads(graph, s$members, s$input_nodes,
                                          s$exports, s$halo, s$out_pad)
    } else if (s$kind == "reduce_partial") {
      rnode <- graph_get(graph, s$members[[1L]])
      pgrid <- graph_get(graph, rnode@parents[[1L]])@grid
      s$fn <- .reduce_partial_fn(rnode, names(pgrid@dims))
    } else if (s$kind == "reduce_combine") {
      s$fn <- .reduce_combine_fn(graph_get(graph, s$members[[1L]]))
    } else {
      s$fn <- .passthrough_fn(s$members[[1L]])
    }
    protos[[i]] <- s
  }

  # Source/warp stages inherit the max NEED (halo + out_pad, D22) of
  # their consumers: satisfied by enlarging the read window (D11).
  for (i in seq_along(protos)) {
    if (!protos[[i]]$kind %in% c("source_read", "warp")) next
    needs <- vapply(protos[cons_idx[[i]]],
                    function(s) as.integer(s$halo + s$out_pad),
                    integer(1))
    protos[[i]]$halo <- if (length(needs)) max(0L, needs) else 0L
  }

  chunk_dim <- .plan_chunk_dim(graph, protos)
  read_px <- .plan_read_px(graph, protos)
  # Per-stage read window target: a source/warp stage is budgeted by
  # ITS consumers' co-resident input sets, not the plan-wide widest
  # stage (a 145-input arm would otherwise shrink an unrelated
  # 64-input arm's windows too).
  read_px_of <- vapply(seq_along(protos), function(i) {
    if (!protos[[i]]$kind %in% c("source_read", "warp")) return(read_px)
    cons <- cons_idx[[i]]
    if (length(cons) == 0L) return(read_px)
    min(vapply(cons, function(j)
      .plan_read_px(graph, protos[j]), numeric(1)))
  }, numeric(1))
  stage_objs <- lapply(protos, function(s) {
    Stage(
      id = as.integer(s$id), kind = s$kind,
      members = as.integer(s$members), fn = s$fn,
      halo = as.integer(s$halo), grid = s$grid,
      chunks = .chunk_for(s$grid, .stage_block(graph, protos, s), s$halo,
                          s$kind, chunk_dim, read_px_of[[s$id]]),
      device = if (s$kind %in% c("compute", "reduce_partial"))
        garry_opt("device") else "cpu",
      inputs = as.integer(s$inputs),
      input_nodes = as.integer(s$input_nodes),
      exports = as.integer(s$exports %||% integer(0)),
      out_pad = as.integer(s$out_pad %||% 0L),
      export_pads = as.integer(s$export_pads %||% integer(0))
    )
  })

  # The merge pass renumbers stages; find the sink by membership. A
  # spatially-reduced root is a member of BOTH its reduce_partial and
  # reduce_combine stages; the combine stage (created later) is the
  # sink, so take the last match.
  sinks <- Filter(function(s) primary_id %in% s$members, protos)
  Plan(stages = stage_objs,
       sink = as.integer(sinks[[length(sinks)]]$id),
       sinks = sink_ids, graph = graph)
}

# Reachable ids from a sink, ascending (= topo in an append-only graph).
.reachable <- function(graph, root_id) {
  nodes <- graph@nodes
  seen <- new.env(parent = emptyenv(), hash = TRUE)
  stack <- root_id
  while (length(stack) > 0L) {
    id <- stack[[length(stack)]]
    stack <- stack[-length(stack)]
    k <- .key(id)
    if (!is.null(seen[[k]])) next
    seen[[k]] <- TRUE
    stack <- c(stack, .node_parents(nodes[[k]]))
  }
  sort(as.integer(ls(seen, all.names = TRUE)))
}

# Within-stage halo: halo required on a member's inputs = its own
# requirement + max over in-stage consumers; stage halo = max over
# members that read stage inputs. `halos` is an optional precomputed
# required_halo lookup (named by node id); when every member's own
# requirement is zero the propagation is all-zero and the O(members^2)
# consumer scan is skipped — the common case, and the merge pass calls
# this once per attempted merge on an ever-growing member list.
.stage_halo <- function(graph, members, input_nodes, halos = NULL) {
  req <- if (is.null(halos)) {
    vapply(members, function(m) required_halo(graph_get(graph, m)),
           integer(1))
  } else {
    unname(halos[as.character(members)])
  }
  if (all(req == 0L)) return(0L)
  H <- stats::setNames(integer(length(members)), as.character(members))
  for (i in rev(seq_along(members))) {
    id <- members[[i]]
    consumers <- Filter(function(m) id %in% .node_parents(graph_get(graph, m)),
                        members)
    downstream <- if (length(consumers) == 0L) 0L
                  else max(vapply(consumers, function(m) H[[.key(m)]],
                                  integer(1)))
    H[[.key(id)]] <- req[[i]] + downstream
  }
  readers <- Filter(function(m) {
    any(.node_parents(graph_get(graph, m)) %in% input_nodes)
  }, members)
  if (length(readers) == 0L) return(0L)
  max(vapply(readers, function(m) H[[.key(m)]], integer(1)))
}

# Native block for a stage: from the SourceNode if declared, else
# unconstrained; compute stages inherit their first input's block.
.stage_block <- function(graph, protos, s) {
  if (s$kind == "source_read") {
    node <- graph_get(graph, s$members[[1L]])
    if (length(node@block_dim) == 2L) return(node@block_dim)
    return(c(1L, 1L))
  }
  if (length(s$inputs) > 0L) {
    return(.stage_block(graph, protos, protos[[s$inputs[[1L]]]]))
  }
  c(1L, 1L)
}

# Per-pixel resident estimate for one stage's chunk task: ~2 f32
# device copies of the widest member + input chunks held as R
# doubles. Calibrated against a measured 55-layer median stage with
# 110 inputs (~1.5 KB/px). An estimate, not a bound. Shared by the
# chunking pass (worst stage caps chunk size) and the pooled
# scheduler's compute-budget balancer (a mask chunk is ~30 B/px, a
# stacked median ~1.3 KB/px — the budget is what lets many small
# tasks and few big ones share the pool safely).
.stage_bytes_per_px <- function(graph, members, input_nodes) {
  outer_max <- max(vapply(members, function(id) {
    d <- graph_get(graph, id)@grid@dims
    prod(d[!names(d) %in% c("x", "y")])
  }, numeric(1)))
  # Inputs price their OUTER dims, not just their count: one coalesced
  # 145-band source input costs what 145 single-band inputs did.
  in_px <- if (length(input_nodes) == 0L) 1 else
    sum(vapply(input_nodes, function(nid) {
      d <- .node_grid(graph_get(graph, nid))@dims
      max(1, prod(d[!names(d) %in% c("x", "y")]))
    }, numeric(1)))
  # A scan body holds far more than its output: the forward pass emits
  # ~7 (T, y, x) f64 state cubes that stay live until the backward
  # pass consumes them (kalman_llt), ~56 x T B/px against the ~8 x T
  # the outer term charges. Without this a scan chunk's true working
  # set is ~6x the model and the chunk sizing oversizes it.
  scan_px <- max(c(0, vapply(members, function(id) {
    n <- graph_get(graph, id)
    if (!S7::S7_inherits(n, ScanNode)) return(0)
    d <- .node_grid(n)@dims
    56 * max(1, prod(d[!names(d) %in% c("x", "y")]))
  }, numeric(1))))
  8 * outer_max + 8 * max(1, in_px) + 16 + scan_px
}

.gcd2 <- function(a, b) if (b == 0L) a else .gcd2(b, a %% b)
.lcm2 <- function(a, b) as.integer(a / .gcd2(a, b) * b)

# Plan-wide chunk dim: ONE spatial tiling for every stage, because the
# executors align input chunks by index, so chunk tables must tile
# identically across stages (sources with different native blocks
# would otherwise snap to different chunk heights). The target aims
# for garry_opt("chunk_target_px") but is capped by the per-worker RAM
# budget against the WORST per-pixel footprint of any stage: a fused
# stage holds device copies of its stacked members (outer dims, e.g.
# t = 55) plus one input buffer per input node. Snapping uses the LCM
# of all stages' native blocks per axis; incommensurable blocks fall
# back to no snapping (alignment is correctness, block snap is only a
# read optimisation).
.plan_chunk_dim <- function(graph, protos) {
  bytes_per_px <- vapply(protos, function(s) {
    .stage_bytes_per_px(graph, s$members, s$input_nodes)
  }, numeric(1))
  px_cap <- garry_opt("ram_budget_mb") * 2^20 / max(bytes_per_px)
  target <- max(1, min(garry_opt("chunk_target_px"), px_cap))
  side <- max(1L, as.integer(floor(sqrt(target))))

  blocks <- lapply(protos, function(s) .stage_block(graph, protos, s))
  block <- vapply(1:2, function(ax) {
    l <- Reduce(.lcm2, vapply(blocks, `[[`, integer(1), ax), 1L)
    if (l > 2L * side) 1L else l
  }, integer(1))
  snap_to_blocks(c(side, side), block)
}

# Chunk-size policy (D14): tile a stage's grid by the plan-wide
# chunk dim. Source/warp stages read COARSER: their chunk dim is an
# integer multiple of the compute chunk dim sized toward
# garry_opt("read_target_px"), and reads split producer-side into
# per-compute-chunk store values (windowed reads of warped mosaics
# decompress the same source blocks whatever the window, so small
# read windows amplify transfer). A halo rides on the coarse window:
# coarse chunks are unions of whole compute chunks, so every compute
# chunk's halo-padded window is contained in the coarse window
# padded by the same halo (phase 11.2: this is what keeps 55
# per-slice mask-cleanup sources at 55 coarse reads instead of
# 55 x chunks halo'd reads).
# Plan-wide coarse-read target, in pixels. Reads want to be big (a
# windowed read of a warped mosaic decompresses the same source blocks
# whatever the window), but a coarse read region stays resident until
# every compute chunk it feeds has retired, and a stage consuming n
# input bands pins ALL n of its regions at once. So the target is
# capped so TWO of the widest stage's full window sets fit in
# garry_opt("read_budget_mb"): one set computing while the next set's
# reads drain (the scheduler launches reads window-major, so sets
# complete contiguously). A 2-input map keeps the full read_target_px;
# a 145-band MLP predict reads in windows ~140x smaller and holds the
# same bytes. The set is priced in BYTES per pixel (4 B x each input's
# outer-dim product), so one coalesced 145-band source input sizes the
# window exactly as 145 per-band inputs did — residency is identical,
# only the task and region count differ.
.plan_read_px <- function(graph, protos) {
  set_bpx <- vapply(protos, function(s) {
    if (length(s$input_nodes) == 0L) return(4)
    sum(vapply(s$input_nodes, function(nid) {
      d <- .node_grid(graph_get(graph, nid))@dims
      4 * max(1, prod(d[!names(d) %in% c("x", "y")]))
    }, numeric(1)))
  }, numeric(1))
  cap <- garry_opt("read_budget_mb") * 2^20 / (2 * max(c(4, set_bpx)))
  max(1, min(garry_opt("read_target_px"), cap))
}

.chunk_for <- function(grid, block, halo, kind, chunk_dim,
                       read_px = garry_opt("read_target_px")) {
  if (kind == "reduce_combine") {
    return(ChunkGrid(grid = grid,
                     chunk_dim = unname(grid@dims[c("x", "y")]),
                     block_dim = c(1L, 1L), halo = 0L))
  }
  if (kind %in% c("source_read", "warp")) {
    nx <- as.integer(grid@dims[["x"]])
    cxy <- as.numeric(chunk_dim)
    if (block[[1L]] >= nx && nx > chunk_dim[[1L]]) {
      # Full-width row bands for full-width-strip sources: a DEFLATE
      # strip decompresses whole whatever the window, so square read
      # windows re-decompress every strip once per window COLUMN
      # (~5x on the 8820-px bc grid). Full-width windows keep the
      # coarse chunks unions of whole compute chunks (integer
      # multiples on both axes), so the split contract holds.
      fx <- as.integer(ceiling(nx / cxy[[1L]]))
      fy <- max(1L, as.integer(floor(
        read_px / (fx * cxy[[1L]] * cxy[[2L]]))))
      chunk_dim <- chunk_dim * c(fx, fy)
    } else {
      f <- max(1L, as.integer(floor(sqrt(
        read_px / prod(cxy)))))
      chunk_dim <- chunk_dim * f
    }
  }
  ChunkGrid(grid = grid, chunk_dim = chunk_dim, block_dim = block,
            halo = as.integer(halo))
}
