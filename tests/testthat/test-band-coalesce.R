# Multi-band read coalescing. A band stack of single-band SourceNodes
# over the SAME file collapses at plan time into one multi-band
# SourceNode carrying the stack's node id: one read task per (file,
# window) instead of one per (band, window). Per-band reads of an
# N-band pixel-interleaved file decompress ~N x the window bytes and
# blow the task count up as bands^2 under the read budget; the
# coalesced plan reads the same bytes once. Gates: the collapse fires
# only when it is safe (same file, same nodata, no warp consumer, not
# a sink), and results are identical to the per-band plan on every
# execution path.

skip_if_not_installed("anvl")

.mb_graph <- function(fx, fn = NULL) {
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  if (is.null(fn)) st else fn(st)
}

test_that("multi-band gdal_read_window matches per-band reads", {
  fx <- fixture_multiband()
  mb <- gdal_read_window(fx$path, seq_len(fx$nb), 7, 5, 31, 22)
  expect_equal(dim(mb), c(fx$nb, 22L, 31L))
  for (b in seq_len(fx$nb)) {
    expect_equal(mb[b, , ],
                 gdal_read_window(fx$path, b, 7, 5, 31, 22))
  }
  raw3 <- gdal_read_window(fx$path, seq_len(fx$nb), 7, 5, 31, 22,
                           out = "raw_f32")
  expect_equal(attr(raw3, "gdim"), c(fx$nb, 22L, 31L))
  expect_equal(.sv_materialise(raw3), mb, tolerance = 1e-6)
})

test_that("same-file band stack collapses to one multi-band source", {
  fx <- fixture_multiband()
  p <- plan_lazy(.mb_graph(fx, function(st)
    reduce_over(st, "mean", "band", nan_rm = TRUE)))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "source_read"), 1L)
  src <- p@stages[[which(kinds == "source_read")]]
  node <- graph_get(p@graph, src@members[[1L]])
  expect_s7_class(node, SourceNode)
  expect_identical(node@band, seq_len(fx$nb))
})

test_that("coalesced results are identical to the per-band plan", {
  fx <- fixture_multiband()
  build <- function(coalesce) {
    old <- options(garry.read_coalesce = coalesce)
    on.exit(options(old), add = TRUE)
    lr <- .mb_graph(fx, function(st)
      reduce_over(st, function(x, dims)
        g_mean(x * 2 + 1, dims = dims, nan_rm = FALSE),
        over = "band") * 0.5)
    execute_plan(plan_lazy(lr))
  }
  expect_equal(build(TRUE), build(FALSE))
  ref <- Reduce(`+`, lapply(fx$vals, function(m) m * 2 + 1)) / fx$nb * 0.5
  expect_equal(build(TRUE), unclass(ref), tolerance = 1e-5,
               ignore_attr = TRUE)
})

test_that("split (coarse) reads keep parity under small chunks", {
  fx <- fixture_multiband()
  old <- options(garry.chunk_target_px = 200)
  on.exit(options(old), add = TRUE)
  lr <- .mb_graph(fx, function(st)
    reduce_over(st, "median", "band", nan_rm = TRUE))
  p <- plan_lazy(lr)
  # coarse read stage splits into >1 compute chunk per window
  expect_gt(nrow(chunk_iter(
    Filter(function(s) s@kind == "compute", p@stages)[[1L]]@chunks)), 1L)
  ref <- apply(simplify2array(fx$vals), c(1, 2), stats::median)
  expect_equal(execute_plan(p), unclass(ref), tolerance = 1e-5,
               ignore_attr = TRUE)
})

test_that("focal after the stack reads a padded multi-band window", {
  fx <- fixture_multiband()
  w <- rep(1 / 9, 9)
  lr <- .mb_graph(fx, function(st)
    reduce_over(focal_kernel(st, matrix(w, 3, 3)), "mean", "band",
                nan_rm = FALSE))
  p <- plan_lazy(lr)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "source_read"), 1L)
  got <- execute_plan(p)
  # oracle: per-band 3x3 mean with NaN boundary, then band mean
  pad_mean <- function(m) {
    ny <- nrow(m); nx <- ncol(m)
    pm <- matrix(NaN, ny + 2L, nx + 2L)
    pm[2:(ny + 1L), 2:(nx + 1L)] <- m
    out <- matrix(0, ny, nx)
    for (dy in -1:1) for (dx in -1:1)
      out <- out + pm[(2 + dy):(ny + 1 + dy), (2 + dx):(nx + 1 + dx)] / 9
    out
  }
  ref <- Reduce(`+`, lapply(fx$vals, pad_mean)) / fx$nb
  expect_equal(got, unclass(ref), tolerance = 1e-4, ignore_attr = TRUE)
})

test_that("stacks across different files do not collapse", {
  fx <- fixture_multiband()
  f2 <- fixture_gradient_f32()
  g <- graph_new()
  st <- lazy_stack(list(lazy_source(fx$path, band = 1L, graph = g),
                        lazy_source(fx$path, band = 2L, graph = g),
                        lazy_source(f2, graph = g)), along = "band")
  p <- plan_lazy(reduce_over(st, "mean", "band", nan_rm = TRUE))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "source_read"), 3L)
})

test_that("a stack requested as a sink keeps its per-band shape", {
  fx <- fixture_multiband()
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st <- lazy_stack(bands, along = "band")
  red <- reduce_over(st, "mean", "band", nan_rm = TRUE)
  p <- plan_lazy(list(cube = st, mean = red))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "source_read"), fx$nb)
  res <- execute_plan(p)
  ref <- Reduce(`+`, fx$vals) / fx$nb
  expect_equal(res$mean, unclass(ref), tolerance = 1e-5, ignore_attr = TRUE)
})

test_that("distributed execution matches memory on a coalesced plan", {
  skip_if_not_installed("mirai")
  skip_if_not_installed("mori")
  skip_on_cran()
  fx <- fixture_multiband()
  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 200)
  on.exit(options(old), add = TRUE)
  lr <- .mb_graph(fx, function(st)
    reduce_over(st, function(x, dims)
      g_sum(x * 0.25, dims = dims, nan_rm = FALSE), over = "band") + 1)
  p <- plan_lazy(lr)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "source_read"), 1L)
  mem <- execute_plan(p)
  dist <- execute_plan_mirai(p)
  expect_equal(dist, mem, tolerance = 1e-6)

  # streamed write path
  dir <- withr::local_tempdir("coalsink")
  path <- file.path(dir, "out.tif")
  execute_plan_mirai(p, path = path)
  d <- methods::new(gdalraster::GDALRaster, path)
  got <- matrix(d$read(1, 0, 0, fx$nx, fx$ny, fx$nx, fx$ny),
                fx$ny, fx$nx, byrow = TRUE)
  d$close()
  expect_equal(got, unclass(mem), tolerance = 1e-6, ignore_attr = TRUE)
})
