# P3: PatchNode IR integration. Gates: output grid algebra; halo
# propagation to source reads; narrow-stage guard (no merge across the
# patch stage); content-addressed kernel signature (never a fn
# serialization); chunk-size invariance for a translation-invariant
# body (the halo mechanics proof); distributed == single-threaded;
# draw/gradient behaviour.


# Translation-invariant toy body: collapse band, add two fixed shifts.
# Size-preserving; needs radius >= 2 to crop the pad-contaminated ring,
# so chunked results must equal whole-frame results exactly.
.toy_patch_fn <- function(x) {
  s <- g_sum(x, dims = 1L)
  sh <- if (garry:::.g_traced(s)) garry:::.g_shape(s) else dim(s)
  sp <- g_pad(s, 2L, value = 0)
  s + 0.5 * g_shift_slice(sp, 2L, 0L, sh[[1L]], sh[[2L]], 2L) +
    0.25 * g_shift_slice(sp, 0L, -2L, sh[[1L]], sh[[2L]], 2L)
}

.toy_patch <- function(out_bands = 0L, kernel_id = "toy-v1") {
  f <- fixture_gradient_f32()
  g <- graph_new()
  st <- lazy_stack(list(lazy_source(f, graph = g),
                        lazy_source(f, graph = g) * 2), along = "band")
  lazy_patch(st, .toy_patch_fn, radius = 2L, out_bands = out_bands,
             kernel_id = kernel_id, bytes_px = 64, flops_px = 500)
}

test_that("output grid drops or replaces the band axis; dtype override", {
  p0 <- .toy_patch()
  expect_identical(names(p0@grid@dims), c("x", "y"))
  expect_identical(p0@grid@dtype, "f32")

  p2 <- .toy_patch(out_bands = 2L)
  expect_identical(unname(p2@grid@dims[["band"]]), 2L)
})

test_that("the patch stage carries its halo; new external inputs stay out", {
  # scalar algebra on the patch output legitimately fuses into the
  # stage (like any focal chain); a map that would bring a NEW external
  # source into the halo stage must not (narrow guard).
  f <- fixture_gradient_f32()
  lr <- .toy_patch() * 2 + 1
  other <- lazy_source(f, graph = lr@graph)
  joined <- lr + other
  p <- plan_lazy(joined)
  patch_stage <- Find(function(s) {
    any(vapply(s@members, function(id)
      S7::S7_inherits(graph_get(p@graph, id), garry::PatchNode), TRUE))
  }, p@stages)
  expect_false(is.null(patch_stage))
  expect_identical(patch_stage@halo, 2L)
  # the two-parent join map is NOT a member of the halo stage
  join_in_stage <- any(vapply(patch_stage@members, function(id) {
    n <- graph_get(p@graph, id)
    S7::S7_inherits(n, garry::MapNode) && length(n@parents) > 1L
  }, TRUE))
  expect_false(join_in_stage)
  # and the join still computes correctly end to end
  got <- execute_plan(p)
  expect_identical(dim(got), dim(execute_plan(plan_lazy(other))))
})

test_that("kernel signature is content-addressed via kernel_id", {
  sig_of <- function(lr) {
    p <- plan_lazy(lr)
    s <- Find(function(s) any(vapply(s@members, function(id)
      S7::S7_inherits(graph_get(p@graph, id), garry::PatchNode), TRUE)),
      p@stages)
    garry:::.stage_kernel_sig(p@graph, s)
  }
  # same id, different closures (weights would differ): same signature
  a <- sig_of(.toy_patch(kernel_id = "k1"))
  b <- sig_of(.toy_patch(kernel_id = "k1"))
  expect_identical(a, b)
  # different id: different signature
  expect_false(identical(a, sig_of(.toy_patch(kernel_id = "k2"))))
})

test_that("chunked equals whole-frame (halo mechanics)", {
  whole <- withr::with_options(list(garry.chunk_target_px = 1e7),
                               execute_plan(plan_lazy(.toy_patch())))
  small <- withr::with_options(list(garry.chunk_target_px = 400),
                               execute_plan(plan_lazy(.toy_patch())))
  expect_identical(dim(whole), dim(small))
  expect_equal(small, whole, tolerance = 1e-6)
})

test_that("patch: distributed == single-threaded", {
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  p <- plan_lazy(.toy_patch())
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-6)
})

test_that("draw renders and gradients refuse", {
  lr <- .toy_patch()
  expect_output(draw(lr), "patch")
  ln <- lazy_source(fixture_gradient_f32())
  expect_error(
    lazy_value_and_grad(
      reduce_over(.toy_patch(), "mean", c("x", "y"), nan_rm = TRUE),
      wrt = ln),
    "not")
})
