# Planner behaviors that only matter at scale: the merge-pass reduce
# barrier must hold when a map FOLLOWS the reduce (a mega-stage
# collapse otherwise inflates the task count ~18x at bc-cohort scale),
# read windows go full-width on full-width-strip sources (a DEFLATE
# strip decompresses whole whatever the window), and each source
# stage's read window is budgeted by ITS consumers' fan-in rather than
# the plan-wide widest stage.

skip_if_not_installed("anvl")

test_that("a post-reduce map does not fold year stages into the join", {
  fx <- fixture_multiband()
  g <- graph_new()
  years <- lapply(1:3, function(yr) {
    bands <- lapply(seq_len(fx$nb), function(b)
      lazy_source(fx$path, band = b, graph = g))
    red <- reduce_over(lazy_stack(bands, along = "band"),
                       "mean", "band", nan_rm = TRUE)
    red * yr + 1        # the post-reduce map that defeated the old guard
  })
  out <- reduce_over(lazy_stack(years, along = "t"), "sum", "t",
                     nan_rm = TRUE)
  p <- plan_lazy(out)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  n_inputs <- vapply(p@stages, function(s) length(s@inputs), integer(1))
  # Per-year reduce stages survive as separate stages; the cross-year
  # join consumes them. A mega-merge would leave ONE compute stage
  # with fan-in = 3 x bands.
  expect_gte(sum(kinds == "compute"), 4L)
  expect_lte(max(n_inputs[kinds == "compute"]), 3L)

  # and the plan still computes the right thing
  band_mean <- Reduce(`+`, fx$vals) / fx$nb
  ref <- Reduce(`+`, lapply(1:3, function(yr) band_mean * yr + 1))
  expect_equal(execute_plan(p), unclass(ref), tolerance = 1e-4,
               ignore_attr = TRUE)
})

test_that("full-width-strip sources read full-width row bands", {
  fx <- fixture_multiband()   # DEFLATE strips: block = nx x 1
  old <- options(garry.chunk_target_px = 100,
                 garry.read_target_px = 100 * 12)
  on.exit(options(old), add = TRUE)
  p <- plan_lazy(reduce_over(
    lazy_stack(lapply(seq_len(fx$nb), function(b)
      lazy_source(fx$path, band = b, graph = graph_new())), along = "band"),
    "mean", "band", nan_rm = TRUE))
  # one coalesced source stage; its read window spans the full width
  src <- Filter(function(s) s@kind == "source_read", p@stages)[[1L]]
  expect_gte(src@chunks@chunk_dim[[1L]], fx$nx)
  # still an integer multiple of the compute chunk on both axes
  cmp <- Filter(function(s) s@kind == "compute", p@stages)[[1L]]
  expect_true(all(src@chunks@chunk_dim %% cmp@chunks@chunk_dim == 0L))
})

test_that("read windows are budgeted per source stage, not plan-wide", {
  fx <- fixture_multiband()
  f2 <- fixture_gradient_f32()
  g <- graph_new()
  # wide arm: 6 per-band maps (maps block coalescing) -> band reduce
  wide <- reduce_over(lazy_stack(lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g) * b), along = "band"),
    "sum", "band", nan_rm = TRUE)
  # narrow arm: 2-slice stack over another file
  narrow <- reduce_over(lazy_stack(list(
    lazy_source(f2, graph = g) * 1,
    lazy_source(f2, graph = g) * 2), along = "t"),
    "sum", "t", nan_rm = TRUE)
  old <- options(garry.chunk_target_px = 100,
                 garry.read_budget_mb = 0.02,
                 garry.read_target_px = 1e7)
  on.exit(options(old), add = TRUE)
  p <- plan_lazy(wide + narrow)
  srcs <- Filter(function(s) s@kind == "source_read", p@stages)
  path_of <- function(s) graph_get(p@graph, s@members[[1L]])@path
  px <- vapply(srcs, function(s) prod(as.numeric(s@chunks@chunk_dim)),
               numeric(1))
  wide_px <- px[vapply(srcs, path_of, character(1)) == fx$path]
  narrow_px <- px[vapply(srcs, path_of, character(1)) == f2]
  # the 2-input arm reads bigger windows than the 6-input arm
  expect_gt(min(narrow_px), max(wide_px))
})
