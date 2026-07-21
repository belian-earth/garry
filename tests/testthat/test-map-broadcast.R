# A purely spatial (y, x) input may join a cube input in lazy_map, so a
# per-pixel plane can be applied across a (t/band, y, x) cube. `fn`
# broadcasts it itself (g_rep_t); nothing in the IR reshapes.
#
# This is what lets a QA plane gate a whole band stack AFTER stacking
# instead of per band: gating per band leaves the stack's parents
# computed, which blocks multi-band read coalescing. Both spellings must
# give identical values, and the post-stack one must collapse the reads.

skip_if_not_installed("anvl")

test_that("a (y, x) plane may join a cube in lazy_map", {
  fx <- fixture_multiband()
  g <- graph_new()
  cube <- lazy_stack(lapply(1:3, function(b)
    lazy_source(fx$path, band = b, graph = g)), along = "band")
  plane <- lazy_source(fx$path, band = 4L, graph = g)
  out <- lazy_map(cube, plane, fn = function(x, p) x + g_rep_t(p, 3L),
                  dtype = "f32")
  expect_s7_class(out, LazyRaster)
  expect_identical(unname(out@grid@dims[["band"]]), 3L)
  got <- execute_plan(plan_lazy(reduce_over(out, "sum", "band",
                                            nan_rm = FALSE)))
  ref <- Reduce(`+`, fx$vals[1:3]) + 3 * fx$vals[[4L]]
  expect_equal(got, unclass(ref), tolerance = 1e-4, ignore_attr = TRUE)
})

test_that("a plane on a DIFFERENT spatial grid is still refused", {
  fx <- fixture_multiband()
  g <- graph_new()
  cube <- lazy_stack(lapply(1:2, function(b)
    lazy_source(fx$path, band = b, graph = g)), along = "band")
  other <- lazy_source(fixture_i16_nodata(), graph = g)     # 70x50 grid
  expect_error(
    lazy_map(cube, other, fn = function(x, p) x + g_rep_t(p, 2L)),
    "same grid")
})

test_that("gating after the stack matches per-band gating and coalesces", {
  fx <- fixture_multiband()
  nf <- fx$nb - 1L                       # last band stands in for QA
  gate <- function(q) g_ifelse(g_is_nodata(q), NaN, 0 * q)
  build <- function(after) {
    g <- graph_new()
    feats <- lapply(seq_len(nf), function(b)
      lazy_source(fx$path, band = b, graph = g))
    qa0 <- lazy_map(lazy_source(fx$path, band = fx$nb, graph = g),
                    fn = gate, dtype = "f32")
    cube <- if (after) {
      lazy_map(lazy_stack(feats, along = "band"), qa0,
               fn = function(x, q) x + g_rep_t(q, nf), dtype = "f32")
    } else {
      lazy_stack(lapply(feats, function(f) f + qa0), along = "band")
    }
    reduce_over(cube, "sum", "band", nan_rm = FALSE)
  }
  n_src <- function(p) sum(vapply(p@stages, function(s)
    s@kind == "source_read", logical(1)))

  # per-band gating leaves one read stage per band; gating the cube
  # collapses the features to ONE multi-band read (+ the QA band)
  expect_identical(n_src(plan_lazy(build(FALSE))), fx$nb)
  expect_identical(n_src(plan_lazy(build(TRUE))), 2L)

  # and the values are identical, not merely close
  expect_equal(execute_plan(plan_lazy(build(TRUE))),
               execute_plan(plan_lazy(build(FALSE))))
})

test_that("multi-export sinks built on separate graphs plan and execute", {
  # Each arm is built on its OWN graph, so plan_lazy imports it into the
  # first arm's graph and renumbers its nodes. The primary sink must be
  # resolved through the MERGED-graph id: using the arm's own node id
  # matches a stage only by numbering coincidence, and when it does not
  # the sink lookup finds nothing and Plan() errors.
  fx <- fixture_multiband()
  arm <- function(bands) {
    g <- graph_new()
    cube <- lazy_stack(lapply(bands, function(b)
      lazy_source(fx$path, band = b, graph = g)), along = "band")
    lazy_stack(list(reduce_over(cube, "sum", "band", nan_rm = FALSE)),
               along = "t")
  }
  p <- plan_lazy(list(a = arm(1:3), b = arm(4:5)))
  expect_true(any(vapply(p@stages, function(s)
    p@sinks[["b"]] %in% s@members, logical(1))))
  res <- execute_plan(p)
  expect_named(res, c("a", "b"))
  expect_equal(res$a[1, , ], unclass(Reduce(`+`, fx$vals[1:3])),
               tolerance = 1e-4, ignore_attr = TRUE)
  expect_equal(res$b[1, , ], unclass(Reduce(`+`, fx$vals[4:5])),
               tolerance = 1e-4, ignore_attr = TRUE)
})
