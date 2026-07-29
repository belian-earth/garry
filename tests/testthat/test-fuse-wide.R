# End-to-end gate for cost-mode fusion of a WIDE kernel (the PR5
# pathway of design/placement-cost-pass.md): with capped readers and
# placement = "cost", a coalesced multi-band MLP chain executes fused
# on the read tasks — no chunk tasks of its own — and the result is
# identical to the single-threaded oracle (which never fuses). This is
# the correctness half of PR5; the wall-time half is the SI predict
# benchmark.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
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

  garry_daemons(4, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
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
  tl <- read.csv(tlog, header = FALSE, col.names = c("ts", "e", "key"))
  expect_false(any(grepl(sprintf("^s%d_c", mlp$compute), tl$key)))
})
