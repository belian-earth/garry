# End-to-end gate for cost-mode fusion of a WIDE kernel (the PR5
# pathway of design/placement-cost-pass.md): with capped readers and
# placement = "cost", a coalesced multi-band MLP chain executes fused
# on the read tasks — no chunk tasks of its own — and the result is
# identical to the single-threaded oracle (which never fuses). This is
# the correctness half of PR5; the wall-time half is the SI predict
# benchmark.

skip_if(Sys.info()[["sysname"]] != "Linux", "affinity is Linux-only")
skip_if(!nzchar(Sys.which("taskset")), "taskset not available")
skip_if(parallel::detectCores() < 5L, "reader cap is a no-op below 5 cores")

test_that("cost mode fuses a multi-band MLP chain onto capped readers", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  fx <- fixture_multiband()
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  w1 <- matrix(runif(8L * fx$nb), 8L)
  w2 <- matrix(runif(8L), 1L)
  pred <- reduce_over(st, mlp_project(list(w1, w2),
                                      list(rep(0, 8L), 0)),
                      over = "band")
  # a trailing spatial reduce keeps the predict chain in its own
  # NON-SINK single-input compute stage (spatial reduces split into
  # partial/combine stages); chunk-local consumers merge into the
  # predict stage and ride the fusion with it
  p <- plan_lazy(reduce_over(pred * 2, "mean", c("x", "y"),
                             nan_rm = TRUE))

  single <- execute_plan(p)

  local_pools(4, 1, gdal_config = TRUE)
  tlog <- tempfile(fileext = ".csv")
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400,
                 garry.task_log = tlog)
  on.exit(options(old), add = TRUE)

  # the pass must have decided FUSE for the MLP chain under this
  # topology (capped readers recorded by garry_daemons)
  tab <- garry_explain_placement(p)
  mlp <- tab[tab$bands > 1L, ]
  expect_identical(mlp$decision, "fuse")

  dist <- execute_plan_mirai(p)
  expect_equal(dist, single, tolerance = 1e-12)

  # fused: the MLP stage ran on its read tasks, no chunk tasks of its own
  tl <- read.csv(tlog)
  expect_false(any(grepl(sprintf("^s%d_c", mlp$compute), tl$key)))
})

test_that("a SINK-shaped MLP predict fuses and streams (the SI shape)", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  # The SI predict collect: per-embedding predictions are multi-export
  # SINKS. Under cost mode they fuse onto the readers and the streaming
  # writers pull each sink chunk out of its source's read task.
  fx <- fixture_multiband()
  g <- graph_new()
  mk_pred <- function(w_out) {
    bands <- lapply(seq_len(fx$nb), function(b)
      lazy_source(fx$path, band = b, graph = g))
    st <- lazy_stack(bands, along = "band")
    w1 <- matrix(runif(w_out * fx$nb), w_out)
    w2 <- matrix(runif(w_out), 1L)
    reduce_over(st, mlp_project(list(w1, w2), list(rep(0, w_out), 0)),
                over = "band")
  }
  sinks <- list(p8 = mk_pred(8L), p16 = mk_pred(16L))
  p <- plan_lazy(sinks)

  single <- execute_plan(p)

  local_pools(4, 1, gdal_config = TRUE)
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  tab <- garry_explain_placement(p)
  expect_true(all(tab$decision == "fuse"))

  # in-memory retrieval from the fused read tasks
  dist <- execute_plan_mirai(p)
  expect_equal(dist$p8, single$p8, tolerance = 1e-12)
  expect_equal(dist$p16, single$p16, tolerance = 1e-12)

  # streamed writes from the fused read tasks
  d <- withr::local_tempdir()
  execute_plan_mirai(p, path = d)
  for (nm in names(sinks)) {
    got <- gdal_read_window(file.path(d, paste0(nm, ".tif")), 1L, 0, 0,
                            ncol(single[[nm]]), nrow(single[[nm]]))
    expect_equal(got, single[[nm]], tolerance = 1e-6, label = nm)
  }
})

test_that("a QA-gated predict (QA as last plane) fuses and matches (the ESD shape)", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  # hutan predict_mlp_lazy's new shape: features + QA in ONE cube, the
  # gate inside mlp_project — single-input, so the big arm can fuse.
  fx <- fixture_multiband()
  g <- graph_new()
  nfe <- fx$nb - 1L
  feats <- lapply(seq_len(nfe), function(b)
    lazy_source(fx$path, band = b, graph = g))
  qa <- lazy_source(fx$path, band = fx$nb, graph = g)
  cube <- lazy_stack(c(feats, list(qa)), along = "band")
  w1 <- matrix(runif(8L * nfe), 8L)
  w2 <- matrix(runif(8L), 1L)
  pred <- reduce_over(cube,
                      mlp_project(list(w1, w2), list(rep(0, 8L), 0),
                                  qa_plane = nfe + 1L, qa_floor = 500),
                      over = "band")
  p <- plan_lazy(list(pred = pred))

  single <- execute_plan(p)
  expect_true(any(is.na(single)))       # the floor gates something
  expect_false(all(is.na(single)))

  local_pools(4, 1, gdal_config = TRUE)
  old <- options(garry.placement = "cost", garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  tab <- garry_explain_placement(p)
  expect_identical(tab$decision, "fuse")
  expect_identical(tab$bands, as.integer(fx$nb))

  dist <- execute_plan_mirai(p)
  expect_equal(dist, single, tolerance = 1e-12)
})
