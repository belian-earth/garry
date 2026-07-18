# Cross-stage halo propagation (D22, design/halo-propagation.md): a
# focal fed by compute stages executes by padding upstream chunks (ring
# recompute) instead of the old D11 placement refusal. Gates: fused
# decode -> stack -> focal equals the materialise-first reference
# (including raster edges under a NaN-non-preserving map), pads cross
# reduce/scan barriers, padded sink exports trim on write, distributed
# == single-threaded, and the one remaining refusal (spatial reduce).

.hp_px <- function(px, code) {
  old <- options(garry.chunk_target_px = px)
  on.exit(options(old))
  force(code)
}

# NaN-non-preserving decode stand-in: an integer cast round-trip turns
# a NaN ring into finite garbage unless the executor re-masks the
# beyond-raster edge (the .exec_mask_edge gate).
.hp_cast_fn <- function(k) {
  force(k)
  function(x) g_cast(g_cast(x * k, "i32"), "f32") * 0.5
}

.hp_mean9 <- function(shifts) Reduce(`+`, shifts) / length(shifts)

# The embed_read shape: three sources, cast maps, band stack, 3x3 focal.
.hp_graph <- function(f) {
  g <- graph_new()
  maps <- lapply(1:3, function(b)
    lazy_map(lazy_source(f, graph = g), fn = .hp_cast_fn(b), dtype = "f32"))
  stk <- lazy_stack(maps, along = "band")
  list(stack = stk, ctx = focal(stk, fn = .hp_mean9, radius = 1L))
}

# Materialise-first reference: write the decoded stack, focal the file.
.hp_reference <- function(f) {
  p <- withr::local_tempfile(fileext = ".tif")
  collect(.hp_graph(f)$stack, path = p, distributed = FALSE)
  g2 <- graph_new()
  cube <- lazy_stack(lapply(1:3, function(b)
    lazy_source(p, band = b, graph = g2)), along = "band")
  collect(focal(cube, fn = .hp_mean9, radius = 1L), distributed = FALSE)
}

test_that("focal over computed maps equals the materialise-first reference", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  ref <- .hp_reference(f)
  for (px in c(300, 1e6)) {   # many chunks (ring recompute) and one
    got <- .hp_px(px, collect(.hp_graph(f)$ctx, distributed = FALSE))
    expect_equal(unclass(got), unclass(ref), tolerance = 1e-6,
                 ignore_attr = TRUE)
    # raster-edge ring: NaN pattern must match the reference exactly
    # (a garbage-valued ring after the cast map would poison borders)
    expect_identical(is.na(unclass(got)), is.na(unclass(ref)))
  }
})

test_that("the plan carries out_pad on the map stages, not a refusal", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  plan <- plan_lazy(.hp_graph(f)$ctx)
  pads <- vapply(plan@stages, function(s) s@out_pad, integer(1))
  kinds <- vapply(plan@stages, function(s) s@kind, character(1))
  expect_true(any(pads[kinds == "compute"] > 0L))
  # source reads inherit need = halo + out_pad
  expect_true(all(vapply(plan@stages[kinds == "source_read"],
                         function(s) s@halo, integer(1)) >= 1L))
})

test_that("multi-export: a padded sink export writes trimmed and exact", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  nodes <- .hp_graph(f)
  ref_stack <- collect(nodes$stack, distributed = FALSE)
  ref_ctx <- .hp_reference(f)
  for (px in c(300, 1e6)) {
    got <- .hp_px(px, collect(list(raw = nodes$stack, ctx = nodes$ctx),
                              distributed = FALSE))
    expect_equal(unclass(got$raw), unclass(ref_stack), tolerance = 1e-6,
                 ignore_attr = TRUE)
    expect_equal(unclass(got$ctx), unclass(ref_ctx), tolerance = 1e-6,
                 ignore_attr = TRUE)
  }
  # file mode: the raw sink chunk carries pad and must trim on write
  dir <- withr::local_tempdir("hp")
  .hp_px(300, collect(list(raw = nodes$stack, ctx = nodes$ctx),
                      path = dir, distributed = FALSE))
  d <- methods::new(gdalraster::GDALRaster, file.path(dir, "raw.tif"))
  on.exit(d$close(), add = TRUE)
  expect_equal(c(d$getRasterXSize(), d$getRasterYSize()), c(60, 40))
  got1 <- matrix(d$read(2, 0, 0, 60, 40, 60, 40), 40, 60, byrow = TRUE)
  expect_equal(got1, unclass(ref_stack)[, , 2], tolerance = 1e-6,
               ignore_attr = TRUE)
})

test_that("focal after a t-reduce recomputes the ring across the barrier", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  build <- function(g) {
    stk <- lazy_stack(lapply(1:3, function(i)
      lazy_source(f, graph = g) * i), along = "t")
    reduce_over(stk, "mean", "t")
  }
  # reference: materialise the composite, focal the file
  p <- withr::local_tempfile(fileext = ".tif")
  collect(build(graph_new()), path = p, distributed = FALSE)
  ref <- collect(focal(lazy_source(p), fn = .hp_mean9, radius = 1L),
                 distributed = FALSE)
  got <- .hp_px(300, collect(focal(build(graph_new()), fn = .hp_mean9,
                                   radius = 1L), distributed = FALSE))
  expect_equal(unclass(got), unclass(ref), tolerance = 1e-6,
               ignore_attr = TRUE)
})

test_that("focal after a scan recomputes the ring across the barrier", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  build <- function(g) {
    stk <- lazy_stack(lapply(1:3, function(i)
      lazy_source(f, graph = g) + i), along = "t")
    sc <- scan_over(stk, function(xs, m)
      g_scan(0, function(c, v) list(carry = c + v, out = c + v),
             xs = xs[[1L]])$out)
    # reduce the scanned axis to a 2D plane for the focal; the scan
    # still runs inside the producer stage. nan_rm = FALSE keeps the
    # NaN ring NaN (a nan_rm sum defines the beyond-edge ring as the
    # empty-set sum 0 -- pre-existing in-stage semantics, also on the
    # classic source-fed path)
    reduce_over(sc, "sum", "t", nan_rm = FALSE)
  }
  p <- withr::local_tempfile(fileext = ".tif")
  collect(build(graph_new()), path = p, distributed = FALSE)
  ref <- collect(focal(lazy_source(p), fn = .hp_mean9, radius = 1L),
                 distributed = FALSE)
  got <- .hp_px(300, collect(focal(build(graph_new()), fn = .hp_mean9,
                                   radius = 1L), distributed = FALSE))
  expect_equal(unclass(got), unclass(ref), tolerance = 1e-6,
               ignore_attr = TRUE)
})

test_that("cross-stage focal towers accumulate pads", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  build <- function(g) {
    a <- lazy_source(f, graph = g)
    f1 <- focal(a + 1, fn = .hp_mean9, radius = 1L)
    # join with a second branch so the narrow rule cuts a stage
    # boundary between the two focals
    stk <- lazy_stack(list(f1, lazy_source(f, graph = g) * 2),
                      along = "band")
    focal(stk, fn = .hp_mean9, radius = 1L)
  }
  # reference: materialise the stacked intermediate, focal the file
  g <- graph_new()
  a <- lazy_source(f, graph = g)
  f1 <- focal(a + 1, fn = .hp_mean9, radius = 1L)
  stk <- lazy_stack(list(f1, lazy_source(f, graph = g) * 2), along = "band")
  p <- withr::local_tempfile(fileext = ".tif")
  collect(stk, path = p, distributed = FALSE)
  g2 <- graph_new()
  cube <- lazy_stack(lapply(1:2, function(b)
    lazy_source(p, band = b, graph = g2)), along = "band")
  ref <- collect(focal(cube, fn = .hp_mean9, radius = 1L),
                 distributed = FALSE)
  got <- .hp_px(300, collect(build(graph_new()), distributed = FALSE))
  expect_equal(unclass(got), unclass(ref), tolerance = 1e-6,
               ignore_attr = TRUE)
})

test_that("distributed == single-threaded for compute-fed focals", {
  skip_if_not_installed("anvl")
  skip_on_cran()
  f <- fixture_gradient_f32()
  nodes <- .hp_graph(f)
  ref <- .hp_px(300, collect(list(raw = nodes$stack, ctx = nodes$ctx),
                             distributed = FALSE))
  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  got <- .hp_px(300, collect(list(raw = nodes$stack, ctx = nodes$ctx),
                             distributed = TRUE))
  expect_equal(unclass(got$raw), unclass(ref$raw), tolerance = 1e-6,
               ignore_attr = TRUE)
  expect_equal(unclass(got$ctx), unclass(ref$ctx), tolerance = 1e-6,
               ignore_attr = TRUE)
  # streamed file writes
  dir <- withr::local_tempdir("hpd")
  .hp_px(300, collect(list(raw = nodes$stack, ctx = nodes$ctx),
                      path = dir, distributed = TRUE))
  d <- methods::new(gdalraster::GDALRaster, file.path(dir, "ctx.tif"))
  on.exit(d$close(), add = TRUE)
  got2 <- matrix(d$read(1, 0, 0, 60, 40, 60, 40), 40, 60, byrow = TRUE)
  refm <- unclass(ref$ctx)[, , 1]
  expect_equal(got2[!is.na(refm)], refm[!is.na(refm)], tolerance = 1e-6,
               ignore_attr = TRUE)
})

test_that("kernel signatures distinguish out_pad", {
  skip_if_not_installed("anvl")
  f <- fixture_gradient_f32()
  plan <- plan_lazy(lazy_source(f) + 1)
  s <- Filter(function(s) s@kind == "compute", plan@stages)[[1L]]
  sig0 <- .stage_kernel_sig(plan@graph, s)
  S7::prop(s, "out_pad") <- 1L
  expect_false(identical(sig0, .stage_kernel_sig(plan@graph, s)))
})
