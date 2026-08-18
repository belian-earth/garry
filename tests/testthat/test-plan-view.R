# plan_view(): interactive Plan DAG (visNetwork htmlwidget). Structure
# only; rendering is visNetwork's problem.

test_that("plan_view mirrors the plan's stages and wiring", {
  skip_if_not_installed("visNetwork")
  f <- fixture_gradient_f32()
  lr <- lazy_source(f)
  p <- plan_lazy(reduce_over(
    lazy_stack(list(lr * 2, lr + 1)), "median", "t", nan_rm = TRUE
  ))

  w <- plan_view(p)
  expect_s3_class(w, "visNetwork")
  expect_s3_class(w, "htmlwidget")

  nodes <- w$x$nodes
  edges <- w$x$edges
  stage_ids <- vapply(p@stages, function(s) s@id, integer(1))
  # every stage plus one output node for the single sink
  expect_setequal(nodes$id, c(stage_ids, length(stage_ids) + 1L))
  expect_identical(nrow(edges),
                   sum(vapply(p@stages, function(s) length(s@inputs),
                              integer(1))) + 1L)
  # the output edge is the dashed one, from the sink stage
  expect_identical(edges$from[edges$dashes], p@sink)
  # sink stage carries the heavy border
  expect_identical(nodes$borderWidth[nodes$id == p@sink], 4L)
  # every stage kind got a shape and colour
  expect_false(anyNA(nodes$shape))
  expect_false(anyNA(nodes$color.border))
  # explicit topological levels: every edge goes to a strictly deeper level
  lvl <- nodes$level[match(edges$to, nodes$id)] -
    nodes$level[match(edges$from, nodes$id)]
  expect_true(all(lvl >= 1L))
  expect_identical(min(nodes$level), 1L)
})

test_that("plan_view subtypes compute stages by fused members", {
  skip_if_not_installed("visNetwork")
  lr <- lazy_source(fixture_gradient_f32())
  # a focal-bearing compute stage reads as focal (hexagon)
  nodes_f <- plan_view(plan_lazy(focal(lr * 2, radius = 1L,
                                       fn = g_mean)))$x$nodes
  expect_true(any(grepl("focal", nodes_f$label) & nodes_f$shape == "hexagon"))

  # a t-axis reduce fuses into the compute stage: the stage reads as the
  # reduce (triangle) and the label carries the op and full composition
  p <- plan_lazy(reduce_over(
    lazy_stack(list(focal(lr * 2, radius = 1L, fn = g_mean), lr + 1)),
    "median", "t", nan_rm = TRUE
  ))
  nodes <- plan_view(p)$x$nodes
  fused <- grepl("reduce·median", nodes$label)
  expect_true(any(fused))
  expect_identical(nodes$shape[fused], "triangle")
  expect_true(any(grepl("focal", nodes$label[fused])))
  # tooltip carries the op composition
  expect_true(any(grepl("ops:", nodes$title)))

  # a spatial reduce is a barrier: partial/combine stages carry the
  # reducer name
  p2 <- plan_lazy(reduce_over(focal(lr + 1, radius = 1L, fn = g_mean),
                              "mean", c("x", "y")))
  nodes2 <- plan_view(p2)$x$nodes
  expect_true(any(grepl("reduce·mean", nodes2$label)))
  expect_true(any(grepl("combine·mean", nodes2$label)))
})

test_that("plan_view accepts a LazyDataset via stack_bands", {
  skip_if_not_installed("visNetwork")
  lr <- lazy_source(fixture_gradient_f32())
  ds <- as_dataset(list(B04 = lr, B08 = lr * 2))
  ds[["ndvi"]] <- (ds[["B08"]] - ds[["B04"]]) / (ds[["B08"]] + ds[["B04"]])
  w <- plan_view(ds)
  expect_s3_class(w, "visNetwork")
  expect_gte(nrow(w$x$nodes), 1L)
  # the derived band is named in the stage that computes it
  expect_true(any(grepl("derive·ndvi", w$x$nodes$label)))
  # the output node describes the product and lists every band
  out <- w$x$nodes[grepl("^output", w$x$nodes$label), ]
  expect_identical(nrow(out), 1L)
  expect_match(out$label, "f32")
  expect_match(out$title, "B04, B08, ndvi")
})

test_that("derive map tags the derivation subgraph, not other bands", {
  skip_if_not_installed("visNetwork")
  lr <- lazy_source(fixture_gradient_f32())
  ds <- as_dataset(list(B04 = lr, B08 = lr * 2))
  ds[["ndvi"]] <- (ds[["B08"]] - ds[["B04"]]) / (ds[["B08"]] + ds[["B04"]])
  dm <- garry:::.pv_derive_map(ds)
  expect_true(all(dm == "ndvi"))
  # the three ndvi MapNodes (minus, plus, divide), nothing upstream
  expect_identical(length(dm), 3L)
  b04_tail <- ds@bands[["B04"]][[1L]]@node_id
  expect_false(as.character(b04_tail) %in% names(dm))

})

test_that("subsetting a dataset does not swallow the graph into derive", {
  # composite-shaped bands (reduce tails): after ds["ndvi"] drops the
  # other bands' names, the walk must stop structurally at the reduces
  skip_if_not_installed("visNetwork")
  f <- fixture_gradient_f32()
  G <- graph_new()
  bands <- lapply(c("B04", "B08"), function(nm) {
    b <- lazy_source(f, graph = G)
    reduce_over(lazy_stack(list(b, b * 2)), "median", "t", nan_rm = TRUE)
  })
  names(bands) <- c("B04", "B08")
  ds <- as_dataset(bands)
  ds[["ndvi"]] <- (ds[["B08"]] - ds[["B04"]]) / (ds[["B08"]] + ds[["B04"]])

  dm <- garry:::.pv_derive_map(ds)
  dm_sub <- garry:::.pv_derive_map(ds["ndvi"])
  expect_identical(sort(names(dm_sub)), sort(names(dm)))
  expect_identical(length(dm_sub), 3L)

  nodes_sub <- plan_view(ds["ndvi"])$x$nodes
  expect_true(any(grepl("reduce·median", nodes_sub$label)))
  expect_identical(sum(grepl("derive·ndvi", nodes_sub$label)), 1L)
})

test_that("derive stage keeps solid edges only from bands it reads", {
  skip_if_not_installed("visNetwork")
  f <- fixture_gradient_f32()
  G <- graph_new()
  bands <- lapply(c("B02", "B04", "B08"), function(nm) {
    b <- lazy_source(f, graph = G)
    reduce_over(lazy_stack(list(b, b * 2)), "median", "t", nan_rm = TRUE)
  })
  names(bands) <- c("B02", "B04", "B08")
  ds <- as_dataset(bands)
  ds[["ndvi"]] <- (ds[["B08"]] - ds[["B04"]]) / (ds[["B08"]] + ds[["B04"]])

  w <- plan_view(ds)
  nodes <- w$x$nodes
  edges <- w$x$edges
  drv <- nodes$id[grepl("derive·ndvi", nodes$label)]
  out <- nodes$id[grepl("^output", nodes$label)]
  # the assembly stack is unbundled from the derive label
  expect_false(any(grepl("stack", nodes$label[nodes$id == drv])))
  # solid edges into the derivation: only B04's and B08's reduces
  expect_identical(sum(edges$to == drv & !edges$dashes), 2L)
  # every assembled band passes through to the output, dashed, plus the
  # sink stage's own write edge
  expect_identical(sum(edges$to == out & edges$dashes), 4L)
})

test_that("plan_lazy and plan_dot accept a LazyDataset", {
  lr <- lazy_source(fixture_gradient_f32())
  ds <- as_dataset(list(B04 = lr, B08 = lr * 2))
  ds[["ndvi"]] <- (ds[["B08"]] - ds[["B04"]]) / (ds[["B08"]] + ds[["B04"]])

  p <- plan_lazy(ds)
  expect_true(S7::S7_inherits(p, Plan))
  # same plan as the explicit stack_bands route
  p2 <- plan_lazy(stack_bands(ds))
  expect_identical(length(p@stages), length(p2@stages))

  d <- plan_dot(ds)
  expect_type(d, "character")
  expect_match(d, "digraph plan")

  g <- garry:::LazyDatasetGroups(groups = list(a = ds), by = "test")
  expect_error(plan_lazy(g), "one execution per group")
})

test_that("plan_view refuses LazyDatasetGroups with guidance", {
  skip_if_not_installed("visNetwork")
  lr <- lazy_source(fixture_gradient_f32())
  ds <- as_dataset(list(V = lr))
  g <- garry:::LazyDatasetGroups(groups = list(a = ds), by = "test")
  expect_error(plan_view(g), "one execution per group")
})

test_that("level_separation and node_spacing set the packed coordinates", {
  skip_if_not_installed("visNetwork")
  f <- fixture_gradient_f32()
  G <- graph_new()
  a <- lazy_source(f, graph = G)
  b <- lazy_source(f, graph = G)
  w <- plan_view(reduce_over(lazy_stack(list(a, b * 2)), "median", "t",
                             nan_rm = TRUE),
                 level_separation = 300, node_spacing = 60)
  nodes <- w$x$nodes
  # levels sit 300px apart on x (including the output column)
  expect_identical(unique(diff(sort(unique(nodes$x)))), 300)
  # the two sources pack 60px apart on y, centred on the midline
  src_y <- sort(nodes$y[nodes$level == 1L])
  expect_identical(diff(src_y), 60)
  expect_identical(sum(src_y), 0)
})

test_that("plan_view accepts a lazy object directly", {
  skip_if_not_installed("visNetwork")
  lr <- lazy_source(fixture_gradient_f32())
  w <- plan_view(lr * 2 + 1)
  expect_s3_class(w, "visNetwork")
  expect_gte(nrow(w$x$nodes), 1L)
})
