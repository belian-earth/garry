#' @include plan.R node.R generics.R ops.R options.R
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

.garry_error <- function(msg, class) {
  stop(errorCondition(msg, class = c(class, "garry_error", "error")))
}

`%||%` <- function(a, b) if (is.null(a)) b else a

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
    nr <- nrow(x) - 2L * r
    nc <- ncol(x) - 2L * r
    offsets <- expand.grid(dx = -r:r, dy = -r:r)   # row-major over (dy, dx)
    shifts <- lapply(seq_len(nrow(offsets)), function(i) {
      g_shift_slice(x, offsets$dy[i], offsets$dx[i], nr, nc, r)
    })
    node@fn(shifts)
  } else if (S7::S7_inherits(node, ReduceNode)) {
    margins <- .dim_margins(parent_dim_names, node@over)
    .apply_reduce(node@op, pv[[1L]], margins, node@nan_rm)
  } else {
    .garry_error(paste0("node class not executable in a compute stage: ",
                        class(node)[[1L]]), "garry_plan_error")
  }
}

# Composed closure for a compute stage: runs members in ascending (topo)
# order, returns the named list of exports.
.compose_stage_fn <- function(graph, members, input_nodes, exports) {
  force(graph); force(members); force(input_nodes); force(exports)
  function(inputs) {
    vals <- new.env(parent = emptyenv())
    for (i in seq_along(input_nodes)) {
      assign(.key(input_nodes[[i]]), inputs[[i]], envir = vals)
    }
    for (id in members) {
      node <- graph_get(graph, id)
      pv <- lapply(node@parents, function(p) get(.key(p), envir = vals))
      pgrid <- graph_get(graph, node@parents[[1L]])@grid
      assign(.key(id),
             .eval_node(node, pv, parent_dim_names = names(pgrid@dims)),
             envir = vals)
    }
    stats::setNames(
      lapply(exports, function(e) get(.key(e), envir = vals)),
      vapply(exports, .key, character(1)))
  }
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

# -- The planner ---------------------------------------------------------------

#' Plan a LazyRaster: run all planner passes and export a Plan.
#'
#' @param x A `LazyRaster`.
#' @return A `Plan`.
#' @export
plan_lazy <- function(x) {
  stopifnot(S7::S7_inherits(x, LazyRaster))
  graph <- x@graph
  ids <- .reachable(graph, x@node_id)

  # ---- Phase A: assign nodes to proto-stages --------------------------------
  protos <- list()                              # id -> mutable list
  node_stage <- new.env(parent = emptyenv())    # node id -> stage id
  closed <- integer(0)                          # stages already consumed

  new_proto <- function(kind, members, grid, inputs, input_nodes) {
    id <- length(protos) + 1L
    protos[[id]] <<- list(id = id, kind = kind, members = members,
                          grid = grid, inputs = unique(inputs),
                          input_nodes = input_nodes, halo = 0L, fn = NULL)
    closed <<- unique(c(closed, inputs))
    id
  }

  for (id in ids) {
    node <- graph_get(graph, id)

    if (S7::S7_inherits(node, SourceNode)) {
      node_stage[[.key(id)]] <-
        new_proto("source_read", id, node@grid, integer(0), id)

    } else if (S7::S7_inherits(node, WarpNode)) {
      pin <- node@parents[[1L]]
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
      pin <- node@parents[[1L]]
      # Partial stage chunks over the INPUT grid (it runs per input
      # chunk); only the combine stage lives on the reduced grid.
      part <- new_proto("reduce_partial", id,
                        graph_get(graph, pin)@grid,
                        node_stage[[.key(pin)]], pin)
      node_stage[[.key(id)]] <-
        new_proto("reduce_combine", id, node@grid, part, id)

    } else {
      # Fusable: MapNode, FocalNode, chunk-local Reduce over t/band.
      parent_sids <- unique(vapply(node@parents,
                                   function(p) node_stage[[.key(p)]],
                                   integer(1)))
      compute_sids <- parent_sids[vapply(parent_sids, function(s)
        protos[[s]]$kind == "compute" && !s %in% closed, logical(1))]

      if (length(compute_sids) == 1L) {
        # Fuse into the single open compute ancestor.
        sid <- compute_sids
        protos[[sid]]$members <- c(protos[[sid]]$members, id)
        ext <- node@parents[!node@parents %in% protos[[sid]]$members &
                            !node@parents %in% protos[[sid]]$input_nodes]
        if (length(ext) > 0L) {
          ext_sids <- vapply(ext, function(p) node_stage[[.key(p)]],
                             integer(1))
          protos[[sid]]$input_nodes <- c(protos[[sid]]$input_nodes, ext)
          protos[[sid]]$inputs <- unique(c(protos[[sid]]$inputs, ext_sids))
          closed <- unique(c(closed, ext_sids))
        }
        protos[[sid]]$grid <- node@grid
        node_stage[[.key(id)]] <- sid
      } else if (length(compute_sids) == 0L) {
        # Join an open compute stage with the identical input set (keeps
        # diamonds in one stage), else start a new one.
        joinable <- Find(function(s) {
          s$kind == "compute" && !s$id %in% closed &&
            setequal(s$inputs, parent_sids)
        }, protos)
        if (is.null(joinable)) {
          node_stage[[.key(id)]] <-
            new_proto("compute", id, node@grid, parent_sids, node@parents)
        } else {
          sid <- joinable$id
          protos[[sid]]$members <- c(protos[[sid]]$members, id)
          protos[[sid]]$input_nodes <-
            unique(c(protos[[sid]]$input_nodes, node@parents))
          protos[[sid]]$grid <- node@grid
          node_stage[[.key(id)]] <- sid
        }
      } else {
        # Distinct compute ancestries meet: consume both, materialised.
        node_stage[[.key(id)]] <-
          new_proto("compute", id, node@grid, parent_sids, node@parents)
      }
    }
  }

  # ---- Phase B: finalise -----------------------------------------------------

  # Exports: members referenced by other stages' input_nodes, plus tail.
  for (i in seq_along(protos)) {
    s <- protos[[i]]
    s$members <- sort(s$members)
    tail_id <- s$members[[length(s$members)]]
    ext_refs <- unlist(lapply(protos[-i], `[[`, "input_nodes"))
    s$exports <- sort(unique(c(intersect(s$members, ext_refs), tail_id)))
    protos[[i]] <- s
  }

  for (i in seq_along(protos)) {
    s <- protos[[i]]
    node <- graph_get(graph, s$members[[1L]])
    if (s$kind == "compute") {
      s$fn <- .compose_stage_fn(graph, s$members, s$input_nodes, s$exports)
      s$halo <- .stage_halo(graph, s$members, s$input_nodes)
      if (s$halo > 0L) {
        in_kinds <- vapply(s$inputs, function(j) protos[[j]]$kind,
                           character(1))
        if (!all(in_kinds %in% c("source_read", "warp")))
          .garry_error(paste0(
            "focal ops are only supported in stages fed directly by a ",
            "source or warp (D11); this stage is fed by: ",
            paste(in_kinds, collapse = ", "),
            ". Materialise first or restructure the pipeline."),
            "garry_focal_placement_error")
      }
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

  # Source/warp stages inherit the max halo of their consumers: halos are
  # satisfied by enlarging the read window (D11).
  for (i in seq_along(protos)) {
    if (!protos[[i]]$kind %in% c("source_read", "warp")) next
    halos <- vapply(Filter(function(s) i %in% s$inputs, protos),
                    function(s) s$halo, integer(1))
    protos[[i]]$halo <- if (length(halos)) max(0L, halos) else 0L
  }

  stage_objs <- lapply(protos, function(s) {
    Stage(
      id = as.integer(s$id), kind = s$kind,
      members = as.integer(s$members), fn = s$fn,
      halo = as.integer(s$halo), grid = s$grid,
      chunks = .chunk_for(s$grid, .stage_block(graph, protos, s), s$halo,
                          s$kind),
      device = "cpu",
      inputs = as.integer(s$inputs),
      input_nodes = as.integer(s$input_nodes)
    )
  })

  Plan(stages = stage_objs, sink = node_stage[[.key(x@node_id)]],
       graph = graph)
}

# Reachable ids from a sink, ascending (= topo in an append-only graph).
.reachable <- function(graph, root_id) {
  seen <- integer(0)
  stack <- root_id
  while (length(stack) > 0L) {
    id <- stack[[1L]]
    stack <- stack[-1L]
    if (id %in% seen) next
    seen <- c(seen, id)
    stack <- c(stack, graph_get(graph, id)@parents)
  }
  sort(seen)
}

# Within-stage halo: halo required on a member's inputs = its own
# requirement + max over in-stage consumers; stage halo = max over
# members that read stage inputs.
.stage_halo <- function(graph, members, input_nodes) {
  H <- stats::setNames(integer(length(members)), as.character(members))
  for (id in rev(members)) {
    consumers <- Filter(function(m) id %in% graph_get(graph, m)@parents,
                        members)
    downstream <- if (length(consumers) == 0L) 0L
                  else max(vapply(consumers, function(m) H[[.key(m)]],
                                  integer(1)))
    H[[.key(id)]] <- required_halo(graph_get(graph, id)) + downstream
  }
  readers <- Filter(function(m) {
    any(graph_get(graph, m)@parents %in% input_nodes)
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

# Chunk-size policy (D14): aim for garry_opt("chunk_target_px") pixels,
# capped by the per-worker RAM budget, snapped to native blocks.
.chunk_for <- function(grid, block, halo, kind) {
  if (kind == "reduce_combine") {
    return(ChunkGrid(grid = grid,
                     chunk_dim = unname(grid@dims[c("x", "y")]),
                     block_dim = c(1L, 1L), halo = 0L))
  }
  bytes <- max(4L, .dtype_width(grid@dtype) %/% 8L)
  px_cap <- garry_opt("ram_budget_mb") * 2^20 / (bytes * 4)
  target <- min(garry_opt("chunk_target_px"), px_cap)
  side <- max(1L, as.integer(floor(sqrt(target))))
  chunk <- snap_to_blocks(c(side, side), block)
  ChunkGrid(grid = grid, chunk_dim = chunk, block_dim = block,
            halo = as.integer(halo))
}
