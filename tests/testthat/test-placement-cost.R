# Cost mode of the placement pass (PR3 of
# design/placement-cost-pass.md). Inert by default
# (garry.placement = "rules"); these tests exercise the cost model
# directly. Gates: MLP flops introspection from the reducer closure;
# the no-thread-cap gate keeps wide kernels off the readers; a real
# cap plus injected constants flips the MLP chain to fuse; mask
# cleanup fuses in both modes; decisions respond to pool width.

skip_if_not_installed("anvl")

.plc <- function(p, ..., mode = "cost") {
  sc <- garry:::.placement_scan(p)
  garry:::.plan_placement(p, sc$consumers_of, sc$warp_only, ...,
                          mode = mode)
}

# 6-band MLP predict chain over the multiband fixture, kept off the
# sink by a trailing spatial reduce (as test-placement.R).
.mlp_plan <- function(fx, w1_out = 8L) {
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  w1 <- matrix(runif(w1_out * fx$nb), w1_out)
  w2 <- matrix(runif(1L * w1_out), 1L)
  pred <- reduce_over(st, mlp_project(list(w1, w2), list(rep(0, w1_out),
                                                         0)),
                      over = "band")
  plan_lazy(reduce_over(pred, "mean", c("x", "y"), nan_rm = TRUE))
}

test_that(".stage_flops_per_px introspects MLP weights and focal windows", {
  fx <- fixture_multiband()
  p <- .mlp_plan(fx)
  cand <- garry:::.placement_candidates(
    p, garry:::.placement_scan(p)$consumers_of,
    garry:::.placement_scan(p)$warp_only)
  expect_true(length(cand) >= 1L)
  C <- p@stages[[cand[[1L]]$cid]]
  fl <- garry:::.stage_flops_per_px(p@graph, C@members)
  # 2 * (8x6 + 1x8) = 112, plus any elementwise members
  expect_gte(fl, 2 * (8 * fx$nb + 8))
  expect_lt(fl, 2 * (8 * fx$nb + 8) + 16)

  # focal = window area
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  pf <- plan_lazy(reduce_over(
    focal(a, radius = 2L, fn = function(sh) Reduce(`+`, sh) / 25) * 2,
    "mean", c("x", "y"), nan_rm = TRUE))
  cf <- Find(function(s) s@kind == "compute", pf@stages)
  expect_gte(garry:::.stage_flops_per_px(pf@graph, cf@members), 25)
})

test_that("without a thread cap, wide kernels stay on the warm pool", {
  fx <- fixture_multiband()
  p <- .mlp_plan(fx, w1_out = 64L)   # 2*(64*6+64) = 896 flops/px > 128
  tab <- .plc(p, n_read = 8L, n_comp = 2L,
              reader_threads = NULL, avail_mb = 64000)$table
  mlp <- tab[tab$bands > 1L, ]
  expect_identical(mlp$decision, "comp")
  expect_match(mlp$reason, "no reader thread cap")
})

test_that("with a thread cap the MLP chain fuses; narrow pools do not", {
  fx <- fixture_multiband()
  p <- .mlp_plan(fx, w1_out = 64L)
  # capped readers: fuse route has full machine width and no shm move
  tab <- .plc(p, n_read = 8L, n_comp = 2L, reader_threads = 2,
              avail_mb = 64000)$table
  mlp <- tab[tab$bands > 1L, ]
  expect_identical(mlp$decision, "fuse")
  expect_lt(mlp$cost_fuse_s, mlp$cost_mat_s)

  # a single capped reader cannot beat the machine-wide warm pool once
  # the kernel dominates the shm move: shrink modelled shm cost to nil
  old <- options(garry.cost_shm_bw_mbs = 1e9)
  on.exit(options(old), add = TRUE)
  tab1 <- .plc(p, n_read = 1L, n_comp = 2L, reader_threads = 2,
               avail_mb = 64000)$table
  mlp1 <- tab1[tab1$bands > 1L, ]
  expect_identical(mlp1$decision, "comp")

  # memory admission: huge pool on a tiny machine refuses fusion
  tab2 <- .plc(p, n_read = 64L, n_comp = 2L, reader_threads = 2,
               avail_mb = 2000)$table
  mlp2 <- tab2[tab2$bands > 1L, ]
  expect_identical(mlp2$decision, "comp")
  expect_match(mlp2$reason, "does not fit")

  # fused window working set: kernels run at READ granularity, so a
  # window whose activation cubes exceed the per-reader budget must
  # materialise (the crop=2048 AEF OOM)
  old_ws <- options(garry.fuse_reader_mb = 1e-4)
  on.exit(options(old_ws), add = TRUE)
  tab3 <- .plc(p, n_read = 8L, n_comp = 2L, reader_threads = 2,
               avail_mb = 64000)$table
  mlp3 <- tab3[tab3$bands > 1L, ]
  expect_identical(mlp3$decision, "comp")
  expect_match(mlp3$reason, "working set")
  options(old_ws)
})

test_that("mask cleanup fuses in both modes; scans never fuse in cost mode", {
  f <- fixture_gradient_f32()
  qa <- lazy_source(f)
  mask <- focal(
    lazy_map(qa, dtype = "f32",
             fn = function(x) g_cast(x > 0.5, "f32")),
    radius = 1L, fn = function(sh) Reduce(`*`, sh))
  G <- qa@graph
  bands <- lapply(1:2, function(i) {
    b <- lazy_source(f, graph = G)
    masked <- lazy_map(b, mask, dtype = "f32",
                       fn = function(x, m) g_ifelse(m > 0.5, NaN, x))
    reduce_over(lazy_stack(list(masked, masked * 2)), "median", "t",
                nan_rm = TRUE)
  })
  p <- plan_lazy(lazy_stack(bands, along = "band"))
  for (m in c("rules", "cost")) {
    tab <- .plc(p, n_read = 4L, n_comp = 2L, avail_mb = 64000,
                mode = m)$table
    expect_true(all(tab$decision == "fuse"), label = m)
  }
})

test_that("garry_explain_placement returns the table without daemons", {
  f <- fixture_gradient_f32()
  qa <- lazy_source(f)
  m <- lazy_map(qa, dtype = "f32", fn = function(x) x * 2)
  p <- plan_lazy(reduce_over(lazy_stack(list(m, m + 1)), "median", "t",
                             nan_rm = TRUE))
  tab <- garry_explain_placement(p, read = 4, compute = 2)
  expect_s3_class(tab, "data.frame")
  expect_true(all(c("decision", "reason", "cost_fuse_s") %in% names(tab)))
})
