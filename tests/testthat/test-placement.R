# Placement pass extraction (PR2 of design/placement-cost-pass.md).
# Rules mode must reproduce the phase 12b predicate exactly:
# single-band source-fed single-consumer chains fuse; coalesced
# multi-band sources stay on the warm pool; sinks and multi-consumer
# sources are not candidates at all. Behavioural equivalence of the
# fused execution is gated by test-compute-on-read.R, unchanged.


.pl <- function(p, mode = "rules") {
  sc <- garry:::.placement_scan(p)
  garry:::.plan_placement(p, sc$consumers_of, sc$warp_only, mode = mode)
}

test_that("single-band source-fed chain fuses with a full spec", {
  f <- fixture_gradient_f32()
  # benchmark-mini shape (as test-compute-on-read): qa source -> mask
  # map+focal chain, consumed by two band medians.
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

  pl <- .pl(p)
  tab <- pl$table
  expect_true(nrow(tab) >= 1L)
  expect_true(all(tab$decision == "fuse"))
  expect_true(all(tab$bands == 1L))

  # the fused spec carries exactly what the task bodies consume
  sid <- tab$source[[1L]]
  spec <- pl$by_source[[garry:::.key(sid)]]
  expect_identical(sort(names(spec)),
                   sort(c("cid", "ck", "fn", "dtype", "out_key",
                          "out_pad", "out_nb", "out_dtype", "ws_mb")))
  expect_identical(spec$cid, tab$compute[[1L]])
  expect_true(isTRUE(pl$fused[[garry:::.key(spec$cid)]]))
  expect_identical(spec$out_nb, 1)
})

test_that("a coalesced multi-band chain is a candidate that stays comp", {
  fx <- fixture_multiband()
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  # a trailing spatial reduce keeps the band-reduce chain in its own
  # NON-SINK compute stage (spatial reduces split partial/combine)
  out <- reduce_over(reduce_over(st, "mean", "band", nan_rm = TRUE) * 2,
                     "mean", c("x", "y"), nan_rm = TRUE)
  p <- plan_lazy(out)

  tab <- .pl(p)$table
  mb <- tab[tab$bands > 1L, ]
  expect_identical(nrow(mb), 1L)
  expect_identical(mb$decision, "comp")
  # not fused: no spec, no fused mark
  expect_null(.pl(p)$by_source[[garry:::.key(mb$source)]])
})

test_that("sink chains are sinkful candidates; multi-consumer sources are not", {
  f <- fixture_gradient_f32()

  # sink fed by one source: a candidate (the scheduler's chunk lookup
  # is fused-aware), but rules mode keeps phase 12b behaviour
  a <- lazy_source(f)
  p1 <- plan_lazy(a * 2 + 1)
  t1 <- .pl(p1)$table
  expect_identical(nrow(t1), 1L)
  expect_identical(t1$decision, "comp")
  expect_match(t1$reason, "sink stage")

  # both consumers of b fuse into ONE stage, so the source has a single
  # consuming stage and the (sink) chain is a candidate; rules mode
  # keeps it materialised
  b <- lazy_source(f)
  p2 <- plan_lazy(reduce_over(lazy_stack(list(b + 1, b * 2)), "median",
                              "t", nan_rm = TRUE))
  t2 <- .pl(p2)$table
  expect_identical(nrow(t2), 1L)
  expect_identical(t2$decision, "comp")
})

test_that("multi-export sink chains round-trip in both placement modes", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  f <- fixture_gradient_f32()
  # y is a single-export source-fed chain AND a requested sink. Under
  # rules it stays materialised (phase 12b, which fused it and wrote
  # all-zero output — the 2026-07-29 find); under cost it FUSES and the
  # streaming writer pulls its chunks from the read tasks.
  a <- lazy_source(f)
  y <- a * 2 + 1
  b <- lazy_source(f, graph = a@graph)
  z <- reduce_over(lazy_stack(list(b + 1, b * 3)), "median", "t",
                   nan_rm = TRUE)
  p <- plan_lazy(list(y = y, z = z))
  tab <- .pl(p)$table
  expect_true(all(tab$decision == "comp"))   # rules: sinks stay put

  single <- execute_plan(p)
  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)
  for (m in c("rules", "cost")) {
    old_m <- options(garry.placement = m)
    dist <- execute_plan_mirai(p)
    expect_equal(dist$y, single$y, tolerance = 1e-12, label = m)
    expect_equal(dist$z, single$z, tolerance = 1e-12, label = m)

    d <- withr::local_tempdir()
    execute_plan_mirai(p, path = d)
    y1 <- gdal_read_window(file.path(d, "y.tif"), 1L, 0, 0,
                           ncol(single$y), nrow(single$y))
    expect_equal(y1, single$y, tolerance = 1e-6, label = m)
    options(old_m)
  }
})

test_that("unknown placement mode errors", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  qa <- lazy_map(a, dtype = "f32", fn = function(x) x + 1)
  p <- plan_lazy(reduce_over(lazy_stack(list(qa, qa * 2)), "median", "t",
                             nan_rm = TRUE))
  expect_error(.pl(p, mode = "bogus"), class = "garry_placement_error")
})

test_that("a source that is itself a sink keeps its window (defect H1)", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  f <- fixture_gradient_f32()
  # Requesting a raw band ALONGSIDE its derived product: the source's
  # only compute consumer must NOT fuse (the stored region would
  # become the kernel export and the raw band would silently vanish),
  # and split-source retrieval must resolve read-window elements.
  a <- lazy_source(f)
  p <- plan_lazy(list(raw = a,
                      doubled = lazy_map(a, dtype = "f32",
                                         fn = function(v) v * 2)))
  expect_true(all(.pl(p, mode = "cost")$table$decision == "comp"))

  single <- execute_plan(p)
  expect_false(is.null(single$raw))

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)
  for (m in c("rules", "cost")) {
    old_m <- options(garry.placement = m)
    dist <- execute_plan_mirai(p)
    expect_equal(dist$raw, single$raw, tolerance = 1e-12, label = m)
    expect_equal(dist$doubled, single$doubled, tolerance = 1e-12,
                 label = m)
    d <- withr::local_tempdir()
    execute_plan_mirai(p, path = d)
    got <- gdal_read_window(file.path(d, "raw.tif"), 1L, 0, 0,
                            ncol(single$raw), nrow(single$raw))
    expect_equal(got, single$raw, tolerance = 1e-6, label = m)
    options(old_m)
  }
})
