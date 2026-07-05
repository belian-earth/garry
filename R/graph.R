# ---------------------------------------------------------------------------
# Graph container.
#
# All mutable state (node table, id counter) lives in an environment held
# as a property of the S7 Graph. The wrapper gives us a typed handle and a
# clean API; the env gives us O(1) lookup and reference semantics so users
# don't have to thread the Graph through every call.
#
# Nodes themselves are immutable S7 values. Rewrites produce new nodes and
# swap env entries.
# ---------------------------------------------------------------------------

#' Compute graph.
#'
#' @param nodes Environment holding the node table and id counter.
#' @return A `Graph`.
#' @export
Graph <- S7::new_class(
  "Graph",
  properties = list(
    nodes = S7::class_environment
  )
)

#' Create an empty graph.
#'
#' @return A `Graph` with no nodes.
#' @export
graph_new <- function() {
  env <- new.env(parent = emptyenv(), hash = TRUE)
  env$.next_id <- 1L
  Graph(nodes = env)
}

# Internal: env key for node id.
.key <- function(id) as.character(id)

#' Add a node. `ctor` is an S7 node constructor; `...` are its properties
#' (the `id` property is assigned here and passed automatically).
#'
#' @param graph A `Graph`.
#' @param ctor S7 node class constructor.
#' @param ... Properties passed to `ctor`.
#' @return The assigned integer id.
#' @export
graph_add <- function(graph, ctor, ...) {
  id   <- graph@nodes$.next_id
  node <- ctor(id = id, ...)
  graph@nodes[[.key(id)]]    <- node
  graph@nodes$.next_id       <- id + 1L
  id
}

#' Look up a node by id.
#'
#' @param graph A `Graph`.
#' @param id Integer node id.
#' @return The `Node`, or `NULL` if absent.
#' @export
graph_get <- function(graph, id) {
  graph@nodes[[.key(id)]]
}

#' All node ids in the graph, in insertion order.
#'
#' @param graph A `Graph`.
#' @return Sorted integer vector of node ids.
#' @export
graph_ids <- function(graph) {
  keys <- ls(graph@nodes, all.names = TRUE)
  keys <- keys[!startsWith(keys, ".")]
  sort(as.integer(keys))
}

#' Topological sort of all node ids. Errors on cycles.
#'
#' @param graph A `Graph`.
#' @return Integer node ids in topological order.
#' @export
graph_toposort <- function(graph) {
  ids <- graph_ids(graph)
  indeg    <- setNames(integer(length(ids)), as.character(ids))
  children <- setNames(vector("list", length(ids)), as.character(ids))

  for (id in ids) {
    n <- graph_get(graph, id)
    for (p in n@parents) {
      indeg[.key(id)] <- indeg[.key(id)] + 1L
      pk <- .key(p)
      children[[pk]] <- c(children[[pk]], id)
    }
  }

  queue <- as.integer(names(indeg)[indeg == 0L])
  order <- integer(0)
  while (length(queue) > 0L) {
    head  <- queue[1L]; queue <- queue[-1L]
    order <- c(order, head)
    for (c in children[[.key(head)]]) {
      indeg[.key(c)] <- indeg[.key(c)] - 1L
      if (indeg[.key(c)] == 0L) queue <- c(queue, c)
    }
  }

  if (length(order) != length(ids))
    stop("graph has a cycle")
  order
}

#' Replace a node in place (for rewrite passes).
#'
#' @param graph A `Graph`.
#' @param id Integer id of the node to replace.
#' @param node The replacement `Node`.
#' @return The replacement node, invisibly.
#' @export
graph_replace <- function(graph, id, node) {
  graph@nodes[[.key(id)]] <- node
  invisible(node)
}

#' Import the subgraph reachable from `root_id` in `src` into `dst`.
#'
#' Node ids are renumbered; a SourceNode identical in (path, band, nodata,
#' grid, dtype) to one already in `dst` is deduplicated (decision D6).
#' Graphs are append-only (rewrites swap nodes in place, ids never
#' reorder), so ascending id order within the reachable set is a valid
#' topological order.
#'
#' @param dst Destination `Graph` (modified by reference).
#' @param src Source `Graph`.
#' @param root_id Id in `src` whose ancestry is imported.
#' @return The id of the imported root in `dst`.
#' @export
graph_import <- function(dst, src, root_id) {
  if (identical(dst@nodes, src@nodes)) return(root_id)

  # Reachable set via reverse DFS over parents.
  seen <- integer(0)
  stack <- root_id
  while (length(stack) > 0L) {
    id <- stack[[1L]]
    stack <- stack[-1L]
    if (id %in% seen) next
    seen <- c(seen, id)
    stack <- c(stack, graph_get(src, id)@parents)
  }
  seen <- sort(seen)

  dst_sources <- Filter(function(n) S7::S7_inherits(n, SourceNode),
                        lapply(graph_ids(dst), function(i) graph_get(dst, i)))

  id_map <- new.env(parent = emptyenv())
  for (id in seen) {
    node <- graph_get(src, id)
    if (S7::S7_inherits(node, SourceNode)) {
      dup <- Find(function(s) .source_identical(s, node), dst_sources)
      if (!is.null(dup)) {
        id_map[[.key(id)]] <- dup@id
        next
      }
    }
    new_parents <- vapply(node@parents,
                          function(p) id_map[[.key(p)]], integer(1))
    new_id <- dst@nodes$.next_id
    node@id <- new_id
    node@parents <- as.integer(new_parents)
    dst@nodes[[.key(new_id)]] <- node
    dst@nodes$.next_id <- new_id + 1L
    id_map[[.key(id)]] <- new_id
    if (S7::S7_inherits(node, SourceNode))
      dst_sources <- c(dst_sources, list(node))
  }
  id_map[[.key(root_id)]]
}

# Internal: are two SourceNodes the same physical source?
.source_identical <- function(a, b) {
  identical(a@path, b@path) &&
    identical(a@band, b@band) &&
    identical(a@nodata, b@nodata) &&
    grid_equal(a@grid, b@grid) &&
    identical(a@grid@dtype, b@grid@dtype)
}
