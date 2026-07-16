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
    nr <- nrow(x) - 2L * r
    nc <- ncol(x) - 2L * r
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

# Trim `d` cells of padding from every side (centered slice).
.trim_to_pad <- function(x, d) {
  d <- as.integer(d)
  if (d == 0L) return(x)
  g_shift_slice(x, 0L, 0L, nrow(x) - 2L * d, ncol(x) - 2L * d, d)
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
  e <- new.env(parent = globalenv())
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
# remaining-pad count: inputs start at the stage halo, focal members
# consume `radius`, and map members that join branches with different
# pads trim the larger to the common minimum (the halo contract in
# plan.R generalised to DAGs).
#
# The closure captures per-member SPECS extracted from the graph, never
# the graph itself: stage closures are serialized to daemons per task,
# and a graph capture multiplies the whole plan into every payload (see
# .slim_fn). rm() below keeps the closure environment minimal.
.compose_stage_fn <- function(graph, members, input_nodes, exports, halo) {
  specs <- lapply(members, function(id) {
    node <- graph_get(graph, id)
    if (S7::S7_inherits(node, MapNode) || S7::S7_inherits(node, FocalNode))
      node@fn <- .slim_fn(node@fn)
    if ((S7::S7_inherits(node, ScanNode) ||
         S7::S7_inherits(node, ReduceNode)) && length(node@fn))
      node@fn <- list(.slim_fn(node@fn[[1L]]))
    list(id = id, node = node,
         pdims = names(graph_get(graph, node@parents[[1L]])@grid@dims))
  })
  force(input_nodes); force(exports); force(halo)
  rm(graph, members)
  function(inputs) {
    vals <- new.env(parent = emptyenv())
    pads <- new.env(parent = emptyenv())
    for (i in seq_along(input_nodes)) {
      k <- .key(input_nodes[[i]])
      assign(k, inputs[[i]], envir = vals)
      assign(k, halo, envir = pads)
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
#     source/warp-fed stage (D11), and padded values never meet stack
#     members inside one stage;
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
        roots <- intersect(p$members, q$input_nodes)
        if (any(vapply(roots, function(m) {
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

  # required_halo is static per node; computed once here, threaded
  # through the merge pass and finalise (S7 dispatch per call adds up
  # over the merge pass's repeated .stage_halo calls).
  halos <- stats::setNames(
    vapply(ids, function(i) required_halo(graph_get(graph, i)), integer(1)),
    as.character(ids))

  # ---- Phase A: assign nodes to proto-stages --------------------------------
  protos <- list()                              # id -> mutable list
  node_stage <- new.env(parent = emptyenv())    # node id -> stage id
  closed <- integer(0)                          # stages already consumed

  new_proto <- function(kind, members, grid, inputs, input_nodes,
                        has_focal = FALSE) {
    id <- length(protos) + 1L
    protos[[id]] <<- list(id = id, kind = kind, members = members,
                          grid = grid, inputs = unique(inputs),
                          input_nodes = input_nodes, halo = 0L,
                          fn = NULL, has_focal = has_focal)
    closed <<- unique(c(closed, inputs))
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
        protos[[s]]$kind == "compute" && !s %in% closed, logical(1))]

      if (length(compute_sids) == 1L) {
        sid <- compute_sids
        ext <- parents[!parents %in% protos[[sid]]$members &
                       !parents %in% protos[[sid]]$input_nodes]
        if (protos[[sid]]$has_focal && length(ext) > 0L) {
          # Halo stages stay NARROW: fusing a node that brings new
          # external inputs into a focal-bearing stage would put the
          # stage's halo on every added source's reads (measured:
          # band reads inheriting the mask chain's halo-7 windows)
          # and widen its export set. Materialise the boundary
          # instead; the merge pass cannot re-fold it (halo > 0).
          # This is also what keeps source-fed kernel chains
          # single-input/single-export for compute-on-read.
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
          closed <- unique(c(closed, ext_sids))
        }
        protos[[sid]]$grid <- .node_grid(node)
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

  # Exports: members referenced by other stages' input_nodes, plus tail.
  all_inputs <- lapply(protos, `[[`, "input_nodes")
  for (i in seq_along(protos)) {
    s <- protos[[i]]
    s$members <- sort(s$members)
    tail_id <- s$members[[length(s$members)]]
    ext_refs <- unlist(all_inputs[-i], use.names = FALSE)
    s$exports <- sort(unique(c(intersect(s$members, ext_refs), tail_id)))
    protos[[i]] <- s
  }

  for (i in seq_along(protos)) {
    s <- protos[[i]]
    node <- graph_get(graph, s$members[[1L]])
    if (s$kind == "compute") {
      s$halo <- .stage_halo(graph, s$members, s$input_nodes, halos)
      s$fn <- .compose_stage_fn(graph, s$members, s$input_nodes,
                                s$exports, s$halo)
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

  chunk_dim <- .plan_chunk_dim(graph, protos)
  stage_objs <- lapply(protos, function(s) {
    Stage(
      id = as.integer(s$id), kind = s$kind,
      members = as.integer(s$members), fn = s$fn,
      halo = as.integer(s$halo), grid = s$grid,
      chunks = .chunk_for(s$grid, .stage_block(graph, protos, s), s$halo,
                          s$kind, chunk_dim),
      device = if (s$kind %in% c("compute", "reduce_partial"))
        garry_opt("device") else "cpu",
      inputs = as.integer(s$inputs),
      input_nodes = as.integer(s$input_nodes),
      exports = as.integer(s$exports %||% integer(0))
    )
  })

  # The merge pass renumbers stages; find the sink by membership. A
  # spatially-reduced root is a member of BOTH its reduce_partial and
  # reduce_combine stages; the combine stage (created later) is the
  # sink, so take the last match.
  sinks <- Filter(function(s) x@node_id %in% s$members, protos)
  Plan(stages = stage_objs,
       sink = as.integer(sinks[[length(sinks)]]$id), graph = graph)
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
  n_in <- max(1L, length(input_nodes))
  8 * outer_max + 8 * n_in + 16
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
.chunk_for <- function(grid, block, halo, kind, chunk_dim) {
  if (kind == "reduce_combine") {
    return(ChunkGrid(grid = grid,
                     chunk_dim = unname(grid@dims[c("x", "y")]),
                     block_dim = c(1L, 1L), halo = 0L))
  }
  if (kind %in% c("source_read", "warp")) {
    f <- max(1L, as.integer(floor(sqrt(
      garry_opt("read_target_px") / prod(as.numeric(chunk_dim))))))
    chunk_dim <- chunk_dim * f
  }
  ChunkGrid(grid = grid, chunk_dim = chunk_dim, block_dim = block,
            halo = as.integer(halo))
}
