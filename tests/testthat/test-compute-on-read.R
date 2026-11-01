# Phase 12b: compute-on-read. A single-consumer compute stage fed by
# exactly one source stage executes inside the source's read tasks;
# only its output is stored and split. Gates: the fused run holds the
# value plain R gives, and the fused stage's own chunk tasks do not
# exist. test-placement.R holds the decisions and the plans that stay
# unfused.


test_that("source-fed kernel chains execute on their read tasks", {
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
  mask <- focal_map(
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

  # Every cell passes the mask's threshold, so the mask holds 1 and masks the
  # raster, except on the edge ring, whose window leaves it: NaN there reads
  # as clear. The medians are of (v, 2v).
  v <- .fixture_values(60, 40)
  ring <- v * 1.5
  ring[2:39, 2:59] <- NaN
  want <- aperm(array(ring, c(40L, 60L, 2L)), c(3L, 1L, 2L))

  local_pools(2, 1, gdal_config = TRUE)
  tlog <- withr::local_tempfile(fileext = ".csv")
  # rules mode: this test gates the fused-execution machinery, and the
  # cost model's fuse/materialise decision depends on the live machine
  # (cores, free RAM); rules fuses this chain unconditionally.
  withr::local_options(garry.chunk_target_px = 400, garry.task_log = tlog,
                       garry.placement = "rules")
  .expect_cells(unclass(execute_plan_mirai(p)), want)

  # the source's reads ran, and the fused stage got no chunk tasks of its own
  keys <- read.csv(tlog)$key
  expect_true(any(startsWith(keys, sprintf("s%d_", p@stages[[mask_sid]]@inputs[[1L]]))))
  expect_false(any(startsWith(keys, sprintf("s%d_", mask_sid))))
})
