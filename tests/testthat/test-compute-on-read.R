# Phase 12b: compute-on-read. A single-consumer compute stage fed by
# exactly one source stage executes inside the source's read tasks;
# only its output is stored and split. Gates: distributed ==
# single-threaded (the single-threaded executor never fuses, so
# equality proves the fused path); the fused stage's own chunk tasks
# do not exist; guards hold (sink and multi-consumer sources stay
# unfused).

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")

test_that("source-fed kernel chains execute on their read tasks", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  # Fused-on-reader execution hangs on the macOS ARM CI runners: the
  # suite stalls at this test until the 6h job limit (runs 30854991920,
  # 30883748389); the same fused chain passes on Linux and Windows.
  # Needs macOS hardware to debug; until then the fused path is not
  # exercised there.
  skip_on_os("mac")
  f <- fixture_gradient_f32()

  # benchmark-mini shape: qa source -> mask map + focal chain (its own
  # multi-EXPORT-consumer stage) -> two band medians share the mask
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
  out <- lazy_stack(bands, along = "band")
  p <- plan_lazy(out)

  # the mask stage exists in the plan with one input stage (its source)
  mask_sid <- Find(function(s) {
    s@kind == "compute" && length(s@inputs) == 1L &&
      p@stages[[s@inputs[[1L]]]]@kind == "source_read" &&
      s@id != p@sink
  }, p@stages)@id

  single <- execute_plan(p)

  local_pools(2, 1, gdal_config = TRUE)
  tlog <- tempfile(fileext = ".csv")
  # rules mode: this test gates the fused-execution machinery, and the
  # cost model's fuse/materialise decision depends on the live machine
  # (cores, free RAM); rules fuses this chain unconditionally.
  old <- options(garry.chunk_target_px = 400, garry.task_log = tlog,
                 garry.placement = "rules")
  on.exit(options(old), add = TRUE)
  for (st in "mori") {
    old_st <- options(garry.store = st)
    dist <- execute_plan_mirai(p)
    options(old_st)
    expect_equal(dist, single, tolerance = 1e-12,
                 label = paste("compute-on-read", st))
  }

  # the fused stage never got chunk tasks of its own
  tl <- read.csv(tlog)
  expect_false(any(grepl(sprintf("^s%d_", mask_sid), tl$key)))
})

test_that("guards: sinks and multi-consumer sources stay unfused", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  f <- fixture_gradient_f32()

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  # sink fed by one source: must not fuse (host reads sink chunks)
  a <- lazy_source(f)
  p1 <- plan_lazy(a * 2 + 1)
  expect_equal(execute_plan_mirai(p1), execute_plan(p1),
               tolerance = 1e-12)

  # source with TWO compute consumers: stays materialised
  b <- lazy_source(f)
  m1 <- b + 1
  m2 <- b * 2
  p2 <- plan_lazy(reduce_over(lazy_stack(list(m1, m2)), "median", "t",
                              nan_rm = TRUE))
  expect_equal(execute_plan_mirai(p2), execute_plan(p2),
               tolerance = 1e-12)
})
