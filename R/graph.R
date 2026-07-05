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
