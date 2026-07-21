# Read residency budget. Source/warp store regions live from launch
# until their last CONSUMER retires, so what a read fleet costs is
# residency, not concurrency. Two mechanisms bound it: the planner
# shrinks the coarse read window as the widest stage's input count
# grows, and the scheduler gates read launches on resident bytes.
# Gates: the window shrinks with band count, a budget far below one
# stage's input set still completes (escape hatch, no deadlock), and
# results are identical to single-threaded whatever the budget.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")

test_that("coarse read window shrinks with the widest stage's inputs", {
  f <- fixture_gradient_f32()
  wide <- function(n) {
    g <- graph_new()
    reduce_over(lazy_stack(lapply(seq_len(n), function(i)
      lazy_source(f, graph = g) * i), along = "band"),
      "sum", "band", nan_rm = TRUE)
  }
  read_px <- function(p) {
    s <- Filter(function(s) s@kind == "source_read", p@stages)[[1L]]
    prod(as.numeric(s@chunks@chunk_dim))
  }
  old <- options(garry.chunk_target_px = 400, garry.read_budget_mb = 1)
  on.exit(options(old), add = TRUE)

  narrow <- read_px(plan_lazy(wide(2)))
  broad <- read_px(plan_lazy(wide(32)))
  expect_true(broad < narrow)

  # Residency, not window size, is what the cap holds constant: bands x
  # window stays inside the budget in both plans.
  expect_lte(32 * broad * 4 / 2^20, 1)
})

test_that("eager release: cross-stage intermediates drop, results identical", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)

  # A stage-crossing pipeline (map -> t-reduce -> map) whose
  # intermediate compute outputs must be droppable mid-run without
  # perturbing the streamed result.
  f <- fixture_gradient_f32()
  g <- graph_new()
  stk <- lazy_stack(lapply(1:6, function(i)
    lazy_source(f, graph = g) * i), along = "t")
  out <- reduce_over(stk, "median", "t", nan_rm = TRUE) * 2 + 1
  dir <- withr::local_tempdir("relstream")
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  collect(out, path = file.path(dir, "out.tif"), distributed = TRUE)
  mem <- collect(out, distributed = FALSE)
  d <- methods::new(gdalraster::GDALRaster, file.path(dir, "out.tif"))
  got <- matrix(d$read(1, 0, 0, 60, 40, 60, 40), 40, 60, byrow = TRUE)
  d$close()
  expect_equal(got, unclass(mem), tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("a read budget below one stage's input set still completes", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)

  f <- fixture_gradient_f32()
  g <- graph_new()
  lr <- reduce_over(lazy_stack(lapply(1:8, function(i)
    lazy_source(f, graph = g) * i), along = "band"),
    "sum", "band", nan_rm = TRUE)
  p <- plan_lazy(lr)
  single <- execute_plan(p)

  for (budget in c(1e-6, 1e6)) {
    old <- options(garry.chunk_target_px = 400,
                   garry.read_budget_mb = budget)
    dist <- execute_plan_mirai(plan_lazy(lr))
    options(old)
    expect_equal(dist, single, tolerance = 1e-12,
                 label = sprintf("read_budget_mb = %g", budget))
  }
})
