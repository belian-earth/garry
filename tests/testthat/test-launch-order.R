# Gap 9 (phase 10): stage launch order is an explicit invariant, not
# an accident of graph-build order. .stage_launch_order() is a
# depth-first postorder from the sink over stage inputs: a topological
# order in which every consumer's producer subtree enqueues
# contiguously (sibling subtrees in input-id order, never
# interleaved). The mirai scheduler inserts tasks in this order and
# launches ready tasks in insertion order, which is what lets band
# k's fused tail overlap band k+1's read drain.

.band_composite <- function(paths, graph_of_first = NULL) {
  masked <- lapply(paths, function(p) {
    x <- lazy_source_stub(p)
    x + 1
  })
  reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
}

test_that("launch order is a topological order over stage inputs", {
  a <- .band_composite(c("a1.tif", "a2.tif"))
  b <- .band_composite(c("b1.tif", "b2.tif"))
  p <- collect(lazy_stack(list(a, b), along = "band"), plan_only = TRUE)

  ord <- garry:::.stage_launch_order(p)
  expect_setequal(ord, seq_along(p@stages))
  seen <- integer(0)
  for (i in ord) {
    expect_true(all(p@stages[[i]]@inputs %in% seen))
    seen <- c(seen, i)
  }
  expect_identical(ord[[length(ord)]], p@sink)
})

test_that("sibling band subtrees never interleave, even when their
           sources were created interleaved", {
  # Interleave the CREATION of the two bands' sources so raw stage-id
  # order (the scheduler's pre-invariant behavior) would interleave
  # their reads.
  a_srcs <- list(); b_srcs <- list()
  for (i in 1:3) {
    a_srcs[[i]] <- lazy_source_stub(sprintf("band_a_%d.tif", i))
    b_srcs[[i]] <- lazy_source_stub(sprintf("band_b_%d.tif", i))
  }
  comp <- function(srcs) {
    reduce_over(lazy_stack(lapply(srcs, function(s) s + 1)),
                "median", "t", nan_rm = TRUE)
  }
  a <- comp(a_srcs)
  b <- comp(b_srcs)
  p <- collect(lazy_stack(list(a, b), along = "band"), plan_only = TRUE)

  ord <- garry:::.stage_launch_order(p)
  src_band <- function(i) {
    s <- p@stages[[i]]
    if (s@kind != "source_read") return(NA_character_)
    path <- p@graph |> graph_get(s@members[[1L]]) |> (\(n) n@path)()
    if (startsWith(path, "band_a")) "a" else "b"
  }
  bands <- vapply(ord, src_band, character(1))
  bands <- bands[!is.na(bands)]
  expect_identical(bands, c(rep("a", 3L), rep("b", 3L)))

  # And each band's reduction stage follows its own sources but
  # precedes the other band's sources.
  is_compute <- vapply(p@stages, function(s) s@kind == "compute",
                       logical(1))
  first_b_src <- min(which(bands == "b"))
  a_tail <- which(vapply(ord, function(i) {
    s <- p@stages[[i]]
    s@kind == "compute" && any(vapply(s@members, function(m)
      S7::S7_inherits(graph_get(p@graph, m), garry:::ReduceNode),
      logical(1))) && i != p@sink
  }, logical(1)))
  # two per-band median stages exist; the first must come before any
  # "b" source in launch order
  src_pos <- which(!is.na(vapply(ord, src_band, character(1))))
  b_src_positions <- src_pos[bands == "b"]
  expect_true(min(a_tail) < min(b_src_positions))
})

test_that("cycle in stage inputs errors", {
  a <- lazy_source_stub("c1.tif")
  p <- collect(a + 1, plan_only = TRUE)
  # corrupt: make stage 1 depend on stage 2
  st <- p@stages
  st[[1L]]@inputs <- 2L
  p2 <- Plan(stages = st, sink = p@sink, graph = p@graph)
  expect_error(garry:::.stage_launch_order(p2), class = "garry_plan_error")
})
