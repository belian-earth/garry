#' @include plan.R
#' @keywords internal
NULL

# Layout framework after targets::tar_visnetwork: explicit topological
# levels on the vertices (visNetwork's hierarchical layout then never
# guesses), physics disabled so nothing drifts after placement, and a
# level separation that widens when levels are crowded.

# Longest-path level per stage: sources at 1, each stage one past its
# deepest input. Stage ids are dense and topo-ordered (inputs have lower
# ids), so a single forward pass suffices.
.plan_stage_levels <- function(stages) {
  lvl <- integer(length(stages))
  for (s in stages) {
    lvl[s@id] <- if (length(s@inputs)) max(lvl[s@inputs]) + 1L else 1L
  }
  lvl
}

# Packed coordinates: x from the level, y by packing each level's nodes
# at a fixed pitch, centred on the diagram's midline, ordered by the
# barycentre of their neighbours (one upward sweep by parents, one
# downward sweep by children). Unlike vis-network's hierarchical block
# layout, which reserves a vertical band per subtree, this keeps every
# level compact so the left-to-right flow stays legible on wide plans.
.pv_coords <- function(stages, levels, sep, spacing) {
  n <- length(stages)
  parents <- lapply(stages, function(s) s@inputs)
  children <- vector("list", n)
  for (s in stages) {
    for (i in s@inputs) {
      children[[i]] <- c(children[[i]], s@id)
    }
  }
  y <- numeric(n)
  place <- function(ids, bary) {
    ids <- ids[order(bary, ids)]
    y[ids] <<- (seq_along(ids) - (length(ids) + 1) / 2) * spacing
    ids
  }
  for (l in seq_len(max(levels))) {          # upward: order by parents
    ids <- which(levels == l)
    bary <- vapply(ids, function(i) {
      if (length(parents[[i]])) mean(y[parents[[i]]]) else i
    }, 0)
    place(ids, bary)
  }
  for (l in rev(seq_len(max(levels) - 1L))) { # downward: order by children
    ids <- which(levels == l)
    bary <- vapply(ids, function(i) {
      if (length(children[[i]])) mean(y[children[[i]]]) else y[i]
    }, 0)
    place(ids, bary)
  }
  data.frame(x = (levels - 1L) * sep, y = y)
}

# Stage visual vocabulary. Compute stages are subtyped by the IR nodes
# fused into them (same classification as draw()); hues stay within the
# 5 validated families (all-pairs on white, dataviz six-checks) and
# shape + label disambiguate within a family, so colour is never the
# only encoding.
# Palette (garry brand), used at full strength: green = IO, teal =
# elementwise, crimson = spatial, amber = reduce/temporal, ink
# (#2e4057) = labels, controls, and highlights. Normal-vision
# separation validates all-pairs on white; the one CVD pair in the 6-8
# warn band and amber's low contrast are carried by shape and direct
# labels. Borders are the fill darkened 25%.
.pv_vocab <- data.frame(
  key   = c("source", "map", "derive", "stack", "mask", "focal", "scan",
            "reduce", "patch", "reduce_partial", "reduce_combine", "warp"),
  label = c("source", "map", "derive", "stack", "mask", "focal", "scan",
            "reduce", "patch", "reduce·partial", "reduce·combine", "warp"),
  shape = c("database", "box", "square", "ellipse", "circle", "hexagon",
            "dot", "triangle", "star", "triangle", "triangleDown",
            "diamond"),
  hue   = c("#4D7962", "#005B69", "#005B69", "#005B69", "#9D3744", "#9D3744",
            "#B28337", "#B28337", "#9D3744", "#B28337", "#B28337", "#9D3744"),
  fill  = c("#66a182", "#00798c", "#00798c", "#00798c", "#d1495b", "#d1495b",
            "#edae49", "#edae49", "#d1495b", "#edae49", "#edae49", "#d1495b"),
  # label colour: white inside the dark teal box/ellipse, ink elsewhere
  # (labels for the other shapes render outside the mark, on white)
  ink   = c("#2e4057", "#FFFFFF", "#2e4057", "#FFFFFF", "#FFFFFF", "#2e4057",
            "#2e4057", "#2e4057", "#2e4057", "#2e4057", "#2e4057", "#2e4057"),
  stringsAsFactors = FALSE
)
.pv_ink <- "#2e4057"    # labels, controls, highlight chrome
.pv_edge <- "#C0C6CD"   # recessive edge grey (ink tint)

# Most-informative-first: a fused stage is identified by its highest-
# signal member (a focal-over-map stage reads as "focal"). A t-axis
# reduce fuses into its compute stage rather than becoming a
# reduce_partial barrier, so "reduce" ranks here too: a median-composite
# stage reads as the reduce, not the stack it fused with. A derived
# band's subgraph outranks stack for the same reason.
.pv_priority <- c("patch", "scan", "reduce", "focal", "derive", "mask",
                  "stack", "map")

# Dataset-level derive provenance: `ds[["ndvi"]] <- ...` records a
# derive step, but the IR nodes are anonymous MapNodes. Recover the
# derivation subgraph per derived band: walk parents from the band's
# tail node(s), tagging and descending through MapNodes only (a
# derivation is the band algebra layered on top of existing bands), and
# stopping at any other node kind and at other named bands' tails. The
# structural stop matters: after `ds["ndvi"]` the other bands' tails
# are no longer named, and a name-based stop alone would swallow the
# whole upstream graph. Returns a named character vector:
# node id -> derived band name.
.pv_derive_map <- function(ds) {
  derived <- unlist(lapply(ds@steps, function(st) {
    if (identical(st$kind, "derive")) st$detail else NULL
  }))
  if (!length(derived)) {
    return(character(0))
  }
  tail_ids <- lapply(ds@bands, function(layers) {
    vapply(layers, function(lr) lr@node_id, integer(1))
  })
  stops <- unlist(tail_ids[setdiff(names(tail_ids), derived)])
  out <- character(0)
  for (nm in intersect(derived, names(tail_ids))) {
    tails <- tail_ids[[nm]]
    frontier <- tails
    seen <- integer(0)
    while (length(frontier)) {
      id <- frontier[[1L]]
      frontier <- frontier[-1L]
      if (id %in% seen || id %in% stops) next
      seen <- c(seen, id)
      n <- graph_get(ds@graph, id)
      if (is.null(n)) next
      if (!S7::S7_inherits(n, MapNode) && !id %in% tails) next
      out[[.key(id)]] <- nm
      frontier <- c(frontier, n@parents)
    }
  }
  out
}

# Dataset provenance for tooltips: node id -> band name and slice label
# (acquisition date for STAC datasets), from the named band layers.
.pv_band_map <- function(ds) {
  out <- list()
  for (bn in names(ds@bands)) {
    layers <- ds@bands[[bn]]
    lnames <- names(layers)
    for (j in seq_along(layers)) {
      slice <- if (!is.null(lnames) && nzchar(lnames[[j]])) {
        lnames[[j]]
      } else {
        NA_character_
      }
      out[[.key(layers[[j]]@node_id)]] <- list(band = bn, slice = slice)
    }
  }
  out
}

# Axis provenance from stack ordering: a stack node's parents are
# ordered exactly as its grid labels (a t-stack's parents follow its
# slice dates; the band-assembly stack's parents follow its band
# names), so parent i inherits label i. Survives reduce_over(), which
# drops the dataset's named layers. Returns node id -> named character
# (axis -> label).
.pv_axis_map <- function(p) {
  out <- list()
  for (s in p@stages) {
    for (id in s@members) {
      n <- graph_get(p@graph, id)
      if (is.null(n) || length(n@parents) < 2L) next
      for (axis in names(n@grid@labels)) {
        labs <- n@grid@labels[[axis]]
        if (length(labs) != length(n@parents)) next
        for (j in seq_along(labs)) {
          k <- .key(n@parents[[j]])
          out[[k]] <- c(out[[k]], stats::setNames(labs[[j]], axis))
        }
      }
    }
  }
  out
}

# Tooltip metadata lines for one stage, harvested from its members:
# band/slice provenance (dataset layer names), per-node parameters
# (source path/band/scale, reduce op/axis, focal radius, scan
# direction), t labels carried by member grids, and band labels on the
# stage's output grid.
.pv_stage_meta <- function(s, graph, band_map, axis_map = list(),
                           drop_band_line = FALSE,
                           extra = character(0)) {
  lines <- extra
  mem <- lapply(s@members, function(id) graph_get(graph, id))

  # stack-ordering provenance: axis labels inherited by this stage's
  # members (dates on slice sources, band names on band tails)
  ax <- do.call(c, unname(Filter(Negate(is.null),
    lapply(s@members, function(id) axis_map[[.key(id)]]))))
  if (length(ax)) {
    for (axis in unique(names(ax))) {
      v <- sort(unique(unname(ax[names(ax) == axis])))
      lines <- c(lines, if (length(v) <= 4L) {
        .glue("{axis}: {paste(v, collapse = ', ')}")
      } else {
        .glue("{axis}: {v[[1L]]} … {v[[length(v)]]} ({length(v)})")
      })
    }
  }

  bm <- Filter(Negate(is.null),
               lapply(s@members, function(id) band_map[[.key(id)]]))
  if (length(bm)) {
    bands <- unique(vapply(bm, `[[`, "", "band"))
    slices <- unique(stats::na.omit(vapply(bm, `[[`, "", "slice")))
    ln <- .glue("band: {paste(bands, collapse = ', ')}")
    if (length(slices)) {
      slices <- sort(slices)
      ln <- if (length(slices) <= 3L) {
        .glue("{ln} · {paste(slices, collapse = ', ')}")
      } else {
        .glue("{ln} · {slices[[1L]]} … ",
              "{slices[[length(slices)]]} ({length(slices)})")
      }
    }
    lines <- c(lines, ln)
  }

  for (n in mem) {
    if (is.null(n)) next
    if (S7::S7_inherits(n, SourceNode)) {
      ln <- if (length(n@name)) {
        .glue("asset: {n@name} · {basename(n@path)}")
      } else {
        .glue("file: {basename(n@path)} ",
              "(band {paste(n@band, collapse = ',')})")
      }
      if (length(n@scale)) {
        ln <- .glue("{ln} · scale {n@scale}")
      }
      lines <- c(lines, ln)
    } else if (S7::S7_inherits(n, ReduceNode)) {
      op <- if (length(n@fn)) "custom" else n@op
      lines <- c(lines, .glue(
        "reduce: {op} over {paste(n@over, collapse = ',')}",
        "{if (isTRUE(n@nan_rm)) ', nan_rm' else ''}"))
    } else if (S7::S7_inherits(n, FocalNode)) {
      lines <- c(lines, .glue("focal: radius {n@radius}, {n@boundary}"))
    } else if (S7::S7_inherits(n, ScanNode)) {
      lines <- c(lines, .glue("scan: over {n@over}, {n@direction}"))
    }
  }

  tl <- unique(unlist(lapply(mem, function(n) {
    if (!is.null(n)) n@grid@labels[["t"]]
  })))
  if (length(tl)) {
    tl <- sort(tl)
    lines <- c(lines, if (length(tl) <= 4L) {
      .glue("t: {paste(tl, collapse = ', ')}")
    } else {
      .glue("t: {tl[[1L]]} … {tl[[length(tl)]]} ({length(tl)})")
    })
  }
  bl <- s@grid@labels[["band"]]
  if (length(bl) && !drop_band_line) {
    lines <- c(lines, .glue("bands: {paste(bl, collapse = ', ')}"))
  }
  unique(lines)
}

# Classify one stage: vocabulary key, display label, and the member
# composition ("focal + 2 map") built from the plan's graph.
# `derive_map` (node id -> band name) relabels a derived band's members
# as "derive·<band>".
.pv_stage_info <- function(s, graph, derive_map = character(0),
                           members = NULL) {
  if (is.null(members)) {
    members <- s@members
  }
  if (s@kind == "source_read") {
    return(list(key = "source", core = "source", comp = "source"))
  }
  if (s@kind == "warp") {
    return(list(key = "warp", core = "warp", comp = "warp"))
  }
  member_kinds <- vapply(members, function(id) {
    nm <- derive_map[.key(id)]
    if (!is.na(nm)) {
      return(.glue("derive·{nm}"))
    }
    n <- graph_get(graph, id)
    if (is.null(n)) {
      "node"
    } else if (S7::S7_inherits(n, ReduceNode)) {
      .glue("reduce·{if (length(n@fn)) 'custom' else n@op}")
    } else {
      .node_kind(n)
    }
  }, "")
  if (s@kind %in% c("reduce_partial", "reduce_combine")) {
    op <- "custom"
    for (id in s@members) {
      n <- graph_get(graph, id)
      if (!is.null(n) && S7::S7_inherits(n, ReduceNode)) {
        op <- if (length(n@fn)) "custom" else n@op
        break
      }
    }
    verb <- if (s@kind == "reduce_partial") "reduce" else "combine"
    return(list(key = s@kind, core = .glue("{verb}·{op}"),
                comp = .pv_comp(member_kinds)))
  }
  base <- sub("·.*$", "", member_kinds)
  key <- .pv_priority[.pv_priority %in% base][1L]
  if (is.na(key)) key <- "map"
  comp <- .pv_comp(member_kinds)
  list(key = key, core = comp, comp = comp)
}

# "reduce·median + stack + 2 map" from a vector of member kinds,
# ordered most-informative-first (qualified kinds like "derive·ndvi"
# sort by their base kind); each derived band appears once, uncounted.
.pv_comp <- function(kinds) {
  u <- unique(kinds)
  pri <- match(sub("·.*$", "", u), .pv_priority)
  pri[is.na(pri)] <- length(.pv_priority) + 1L
  parts <- vapply(u[order(pri)], function(k) {
    if (startsWith(k, "derive·")) {
      return(k)
    }
    n <- sum(kinds == k)
    if (n > 1L) .glue("{n} {k}") else k
  }, "")
  paste(parts, collapse = " + ")
}

#' Interactive Plan viewer.
#'
#' Renders a `Plan` as an interactive DAG (an htmlwidget, via the
#' suggested \pkg{visNetwork} package): one node per stage, laid out
#' left to right in execution order on explicit topological levels.
#' Stages are labelled by what they compute, not just their scheduler
#' kind: a compute stage is classified by the IR nodes fused into it
#' (`focal`, `scan`, `patch`, `stack`, `map`, most informative first,
#' the same vocabulary as [draw()]), and reduce stages carry their
#' reducer (`reduce·median`). When a `LazyDataset` is passed, derived
#' bands (`ds[["ndvi"]] <- ...`) are recovered from the dataset's step
#' record and the stage computing one is labelled with the band name
#' (`derive·ndvi`); the derivation is bounded structurally at the first
#' non-elementwise node, so it survives subsetting (`ds["ndvi"]`).
#' Hovering a stage shows its full op composition and any recoverable
#' metadata — acquisition dates on slice sources and t-spans on
#' composites (from stack ordering and grid labels), the band a stage
#' computes, source file and band, and op parameters (reducer and
#' axis, focal radius, scan direction) — plus members, halo, device,
#' and output grid; clicking
#' highlights its neighbours; the sink stage is drawn with a heavy
#' border. Where [plan_dot()] emits static Graphviz
#' text, `plan_view()` is the exploratory sibling: watch the plan
#' change shape as a pipeline is composed.
#'
#' @param x A `Plan` from [plan_lazy()], a `LazyRaster`, a
#'   `LazyDataset` (its bands are assembled along the band axis first,
#'   as in [collect()]), or a named list of `LazyRaster`s.
#' @param level_separation Horizontal distance between topological
#'   levels, in pixels. `NULL` (default) adapts to the graph's shape:
#'   wide plans (many sources, few levels) get a landscape aspect so
#'   the left-to-right flow stays legible, floored by label clearance
#'   and capped for deep plans. Pass a number to override.
#' @param node_spacing Distance between nodes within a level, in
#'   pixels — vertical, since levels run left to right. The tall
#'   stretch of a wide plan (e.g. one source per time slice) is this
#'   times the widest level's node count; lower it to compress.
#' @param height,width Widget size, as CSS units.
#' @return A `visNetwork` htmlwidget.
#' @seealso [plan_dot()] for DOT text, [draw()] for pixels.
#' @examples
#' \dontrun{
#' lr <- lazy_source("cube.tif")
#' plan_view(focal(lr * 2, radius = 1L, fn = g_mean))
#' }
#' @export
plan_view <- function(x, level_separation = NULL, node_spacing = 90,
                      height = "600px", width = "100%") {
  rlang::check_installed("visNetwork",
                         reason = "to render interactive plan graphs")
  if (S7::S7_inherits(x, LazyDatasetGroups)) {
    cli::cli_abort(c(
      "{.cls LazyDatasetGroups} plans one execution per group.",
      "i" = "Pick one group, e.g. {.code plan_view(x@groups[[1]])}."
    ))
  }
  derive_map <- character(0)
  band_names <- NULL
  band_map <- list()
  if (S7::S7_inherits(x, LazyDataset)) {
    derive_map <- .pv_derive_map(x)
    band_names <- names(x@bands)
    band_map <- .pv_band_map(x)
    x <- stack_bands(x)
  }
  p <- if (S7::S7_inherits(x, Plan)) x else plan_lazy(x)

  levels <- .plan_stage_levels(p@stages)
  axis_map <- .pv_axis_map(p)
  info <- lapply(p@stages, .pv_stage_info, graph = p@graph,
                 derive_map = derive_map)
  sinks <- if (length(p@sinks)) p@sinks else stats::setNames(integer(0), NULL)

  # Dataset sinks fuse the band-assembly stack with any derivation, so
  # every band's tail feeds the sink stage even when the derivation
  # consumes only some bands. Unbundle: the stage keeps solid edges only
  # from bands its derivation actually reads; assembled bands connect to
  # the output node directly (dashed, pass-through), and the stage label
  # drops the assembly stack.
  reroute <- NULL
  if (!is.null(band_names) && length(sinks) == 1L) {
    S <- Find(function(s) sinks[[1L]] %in% s@members, p@stages)
    if (!is.null(S)) {
      non_stack <- setdiff(S@members, sinks[[1L]])
      tagged <- any(vapply(non_stack, function(id)
        !is.na(derive_map[.key(id)]), TRUE))
      if (length(non_stack) && tagged) {
        drv_par <- unique(unlist(lapply(non_stack, function(id)
          graph_get(p@graph, id)@parents)))
        stk_par <- graph_get(p@graph, sinks[[1L]])@parents
        solid <- S@inputs[vapply(S@inputs, function(i)
          any(p@stages[[i]]@exports %in% drv_par), TRUE)]
        pass <- S@inputs[vapply(S@inputs, function(i)
          any(p@stages[[i]]@exports %in% stk_par), TRUE)]
        info[[S@id]] <- .pv_stage_info(S, p@graph, derive_map,
                                       members = non_stack)
        reroute <- list(sid = S@id, solid = solid, pass = pass)
      }
    }
  }
  # Default level separation adapts to the graph's shape: wide enough
  # that the drawing lands at a landscape aspect (the vertical span is
  # fixed by the widest level), floored by label clearance and capped
  # so deep plans don't sprawl.
  sep <- if (is.null(level_separation)) {
    spacing <- as.numeric(node_spacing)
    v_span <- (max(table(levels)) - 1) * spacing
    gaps <- max(levels)  # stage level gaps + the output column
    label_px <- 7.5 * max(nchar(vapply(info, `[[`, "", "core"))) + 110
    min(1100, max(300, label_px, 2.2 * v_span / gaps))
  } else {
    as.numeric(level_separation)
  }
  coords <- .pv_coords(p@stages, levels, sep, as.numeric(node_spacing))
  ki <- match(vapply(info, `[[`, "", "key"), .pv_vocab$key)

  # A rerouted derive stage lists what its derivation reads (the bands
  # behind its solid inputs) instead of the assembly's band roster,
  # which the output node carries.
  rerouted <- vapply(p@stages, function(s)
    !is.null(reroute) && s@id == reroute$sid, TRUE)
  reads_line <- character(0)
  if (any(rerouted)) {
    reads <- unique(unlist(lapply(reroute$solid, function(i) {
      unlist(lapply(p@stages[[i]]@exports, function(e) {
        ax <- axis_map[[.key(e)]]
        unname(ax[names(ax) == "band"])
      }))
    })))
    if (length(reads)) {
      reads_line <- .glue("reads: {paste(sort(reads), collapse = ', ')}")
    }
  }

  rows <- lapply(seq_along(p@stages), function(i) {
    s <- p@stages[[i]]
    k <- .pv_vocab[ki[[i]], ]
    dims <- paste(s@grid@dims, collapse = " x ")
    data.frame(
      id = s@id,
      label = .glue("[{s@id}] {info[[i]]$core}"),
      level = levels[s@id],
      x = coords$x[s@id],
      y = coords$y[s@id],
      shape = k$shape,
      color.background = k$fill,
      color.border = k$hue,
      color.highlight.background = k$fill,
      color.highlight.border = .pv_ink,
      font.color = k$ink,
      borderWidth = if (s@id == p@sink) 4L else 2L,
      title = .glue(
        "<b>stage {s@id}</b> &middot; {s@kind}",
        "{if (s@id == p@sink) ' &middot; sink' else ''}<br>",
        "ops: {info[[i]]$comp}<br>",
        "{paste0(.pv_stage_meta(s, p@graph, band_map, axis_map,
                                drop_band_line = rerouted[[i]],
                                extra = if (rerouted[[i]]) reads_line
                                        else character(0)),
                 '<br>', collapse = '')}",
        "members: {paste(s@members, collapse = ', ')}<br>",
        "halo: {s@halo} &middot; device: {s@device}<br>",
        "grid: {dims} ({s@grid@dtype})"
      ),
      stringsAsFactors = FALSE
    )
  })
  nodes <- do.call(rbind, rows)

  edges <- do.call(rbind, lapply(p@stages, function(s) {
    ins <- s@inputs
    if (!is.null(reroute) && s@id == reroute$sid) {
      ins <- reroute$solid
    }
    if (!length(ins)) return(NULL)
    data.frame(from = ins, to = s@id, dashes = FALSE)
  }))
  if (is.null(edges)) {
    edges <- data.frame(from = integer(0), to = integer(0),
                        dashes = logical(0))
  }

  # Output nodes: one per sink, to the right of the stage that computes
  # it, describing the written product (dims, dtype, band names). The
  # dashed edge marks the compute -> write boundary.
  out_rows <- lapply(seq_along(sinks), function(i) {
    sid <- Find(function(s) sinks[[i]] %in% s@members, p@stages)
    if (is.null(sid)) {
      return(NULL)
    }
    nm <- names(sinks)[[i]]
    nm <- if (is.null(nm) || nm %in% c("", "sink")) "output" else nm
    dims <- paste(sid@grid@dims, collapse = " x ")
    bands <- if (!is.null(band_names) && length(sinks) == 1L) {
      band_names
    }
    data.frame(
      id = length(p@stages) + i,
      label = .glue("{nm}\n{dims} {sid@grid@dtype}"),
      level = max(levels) + 1L,
      x = max(coords$x) + sep,
      y = coords$y[sid@id],
      shape = "box",
      color.background = "#FFFFFF",
      color.border = .pv_ink,
      color.highlight.background = "#FFFFFF",
      color.highlight.border = .pv_ink,
      font.color = .pv_ink,
      borderWidth = 2L,
      title = .glue(
        "<b>{nm}</b><br>grid: {dims} ({sid@grid@dtype})",
        "{if (!is.null(bands)) paste0('<br>bands: ',
          paste(bands, collapse = ', ')) else ''}"
      ),
      stringsAsFactors = FALSE
    )
  })
  out_rows <- Filter(Negate(is.null), out_rows)
  if (length(out_rows)) {
    out_nodes <- do.call(rbind, out_rows)
    sink_stage_ids <- vapply(seq_along(sinks), function(i) {
      Find(function(s) sinks[[i]] %in% s@members, p@stages)@id
    }, integer(1))
    nodes <- rbind(nodes, out_nodes)
    edges <- rbind(edges, data.frame(from = sink_stage_ids,
                                     to = out_nodes$id, dashes = TRUE))
    if (!is.null(reroute) && length(reroute$pass)) {
      edges <- rbind(edges, data.frame(from = reroute$pass,
                                       to = out_nodes$id[[1L]],
                                       dashes = TRUE))
    }
  }

  legend <- lapply(sort(unique(ki)), function(j) {
    k <- .pv_vocab[j, ]
    list(label = k$label, shape = k$shape, size = 14,
         color = list(background = k$fill, border = k$hue),
         font = list(color = k$ink, size = 12))
  })
  if (length(out_rows)) {
    legend <- c(legend, list(list(
      label = "output", shape = "box", size = 14,
      color = list(background = "#FFFFFF", border = .pv_ink),
      font = list(color = .pv_ink, size = 12)
    )))
  }

  visNetwork::visNetwork(nodes, edges, height = height, width = width,
                         background = "#ffffff") |>
    visNetwork::visNodes(
      physics = FALSE,
      font = list(color = .pv_ink, size = 14,
                  face = "system-ui, -apple-system, sans-serif")
    ) |>
    visNetwork::visEdges(
      arrows = list(to = list(enabled = TRUE, scaleFactor = 0.6)),
      color = list(color = .pv_edge, highlight = .pv_ink),
      width = 1.5,
      smooth = list(type = "cubicBezier", forceDirection = "horizontal")
    ) |>
    visNetwork::visPhysics(stabilization = FALSE) |>
    visNetwork::visOptions(
      highlightNearest = list(enabled = TRUE, degree = 1, hover = TRUE,
                              algorithm = "hierarchical")
    ) |>
    visNetwork::visLegend(useGroups = FALSE, addNodes = legend,
                          ncol = 1L, position = "right", width = 0.15) |>
    visNetwork::visInteraction(navigationButtons = TRUE, tooltipDelay = 100) |>
    htmlwidgets::prependContent(htmltools::tags$style(paste0(
      # navigation controls: drop the stock sprites (the grey circle is
      # baked into the image) and draw plain glyphs in the palette ink
      ".vis-network div.vis-navigation div.vis-button",
      "{ background-image: none !important; width: 30px; height: 30px;",
      "  display: flex; align-items: center; justify-content: center;",
      "  color: ", .pv_ink, "; font-size: 20px; line-height: 1;",
      "  opacity: 0.75; }",
      ".vis-network div.vis-navigation div.vis-button:hover",
      "{ opacity: 1; box-shadow: none; }",
      ".vis-button.vis-up::after { content: '\\25B2'; }",
      ".vis-button.vis-down::after { content: '\\25BC'; }",
      ".vis-button.vis-left::after { content: '\\25C0'; }",
      ".vis-button.vis-right::after { content: '\\25B6'; }",
      ".vis-button.vis-zoomIn::after { content: '\\FF0B'; }",
      ".vis-button.vis-zoomOut::after { content: '\\2212'; }",
      ".vis-button.vis-zoomExtends::after { content: '\\2922'; }"
    )))
}
