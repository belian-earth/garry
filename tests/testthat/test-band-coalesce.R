# Multi-band read coalescing. A band stack of single-band SourceNodes
# over the SAME file collapses at plan time into one multi-band
# SourceNode carrying the stack's node id: one read task per (file,
# window) instead of one per (band, window). Per-band reads of an
# N-band pixel-interleaved file decompress ~N x the window bytes and
# blow the task count up as bands^2 under the read budget; the
# coalesced plan reads the same bytes once. Gates: the collapse fires
# only when it is safe (same file, same nodata, no warp consumer),
# sink stacks included (issue #25: a written stack of same-file bands
# then needs no compute stage at all), and results are identical to
# the per-band plan on every execution path.


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

test_that("a stack requested as a sink collapses too, alone or beside a consumer", {
  fx <- fixture_multiband()
  # sink only: one read stage whose windows are compute-chunk sized
  # (issue #25: the write is the only consumer, so nothing amortises a
  # coarse window and the writer streams as each read lands)
  st <- .mb_graph(fx)
  p <- plan_lazy(st)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(kinds, "source_read")
  expect_identical(graph_get(p@graph, p@stages[[1]]@members[[1]])@band,
                   seq_len(fx$nb))
  pc <- plan_lazy(.mb_graph(fx, function(st) st * 2))
  src <- Filter(function(s) s@kind == "source_read", pc@stages)[[1]]
  expect_true(prod(p@stages[[1]]@chunks@chunk_dim) <=
              prod(src@chunks@chunk_dim))
  cube <- execute_plan(p)
  for (b in seq_len(fx$nb)) {
    expect_equal(cube[b, , ], unclass(fx$vals[[b]]), tolerance = 1e-6,
                 ignore_attr = TRUE)
  }
  # sink AND consumer (multi-export): the cube is retrieved from the
  # coarse split read regions the reduce also consumes
  g <- graph_new()
  bands <- lapply(seq_len(fx$nb), function(b)
    lazy_source(fx$path, band = b, graph = g))
  st2 <- lazy_stack(bands, along = "band")
  red <- reduce_over(st2, "mean", "band", nan_rm = TRUE)
  p2 <- plan_lazy(list(cube = st2, mean = red))
  kinds <- vapply(p2@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "source_read"), 1L)
  res <- execute_plan(p2)
  ref <- Reduce(`+`, fx$vals) / fx$nb
  expect_equal(res$mean, unclass(ref), tolerance = 1e-5, ignore_attr = TRUE)
  expect_equal(res$cube, cube, tolerance = 0, ignore_attr = TRUE)
})

test_that("a coalesced sink stack writes and collects identically on every path", {
  skip_on_cran()
  fx <- fixture_multiband()
  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 200)
  on.exit(options(old), add = TRUE)
  # permuted band order must survive the collapse
  ord <- c(4L, 1L, 6L, 3L)
  g <- graph_new()
  st <- lazy_stack(lapply(ord, function(b)
    lazy_source(fx$path, band = b, graph = g)), along = "band")
  p <- plan_lazy(st)
  expect_identical(length(p@stages), 1L)
  expect_identical(graph_get(p@graph, p@stages[[1]]@members[[1]])@band, ord)
  mem <- execute_plan(p)
  dist <- execute_plan_mirai(p)
  expect_equal(dist, mem, tolerance = 0)
  for (k in seq_along(ord)) {
    expect_equal(mem[k, , ], unclass(fx$vals[[ord[k]]]), tolerance = 1e-6,
                 ignore_attr = TRUE)
  }
  dir <- withr::local_tempdir("coalsink2")
  out_d <- file.path(dir, "dist.tif")
  out_s <- file.path(dir, "single.tif")
  write_tif(st, out_d, distributed = TRUE)
  write_tif(st, out_s, distributed = FALSE)
  for (k in seq_along(ord)) {
    d <- gdal_read_window(out_d, k, 0L, 0L, fx$nx, fx$ny)
    s <- gdal_read_window(out_s, k, 0L, 0L, fx$nx, fx$ny)
    expect_identical(d, s)
    expect_equal(d, unclass(fx$vals[[ord[k]]]), tolerance = 1e-6,
                 ignore_attr = TRUE)
  }
  # a multi-export with the stack as one sink streams both to disk
  red <- reduce_over(st, "mean", "band", nan_rm = TRUE)
  write_tif(list(cube = st, mean = red), dir, distributed = TRUE)
  got <- gdal_read_window(file.path(dir, "cube.tif"), 2L, 0L, 0L, fx$nx, fx$ny)
  expect_equal(got, unclass(fx$vals[[ord[2]]]), tolerance = 1e-6,
               ignore_attr = TRUE)
  m <- gdal_read_window(file.path(dir, "mean.tif"), 1L, 0L, 0L, fx$nx, fx$ny)
  expect_equal(m, unclass(Reduce(`+`, fx$vals[ord]) / length(ord)),
               tolerance = 1e-5, ignore_attr = TRUE)
})

test_that("distributed execution matches memory on a coalesced plan", {
  skip_on_cran()
  fx <- fixture_multiband()
  local_pools(2, 1, gdal_config = TRUE)
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

# A band stack of warps over one file (lazy_dataset() on a target grid)
# collapses into one multi-band warp. Three target grids cover the three
# read plans a warp can take: a pixel-aligned crop and a 2x decimation
# (both served by a direct RasterIO read) and a half-pixel shift (the
# warped VRT).
.mb_targets <- function(fx) {
  crs <- "EPSG:32632"
  list(
    crop = grid_spec(crs, c(500100, 4599700, 500450, 4599950), res = 10),
    decim = grid_spec(crs, c(500000, 4599600, 500600, 4600000), res = 20),
    shift = grid_spec(crs, c(500005, 4599705, 500455, 4599955), res = 10)
  )
}

.mb_warped <- function(fx, grid, resampling = "near", coalesce = TRUE) {
  old <- options(garry.read_coalesce = coalesce)
  on.exit(options(old), add = TRUE)
  ds <- lazy_dataset(fx$path, grid, resampling = resampling)
  p <- plan_lazy(stack_bands(ds))
  list(plan = p, value = execute_plan(p))
}

test_that("a band stack of same-file warps collapses to one multi-band warp", {
  fx <- fixture_multiband()
  for (nm in names(.mb_targets(fx))) {
    r <- .mb_warped(fx, .mb_targets(fx)[[nm]])
    kinds <- vapply(r$plan@stages, function(s) s@kind, character(1))
    # the warp's source keeps a (warp-only, never read) source stage
    expect_identical(sort(kinds), c("source_read", "warp"), label = nm)
    w <- graph_get(r$plan@graph, r$plan@stages[[which(kinds == "warp")]]@members[[1L]])
    expect_s7_class(w, WarpNode)
    expect_identical(w@bands, seq_len(fx$nb))
  }
})

test_that("collapsed warps read the same values as per-band warps", {
  fx <- fixture_multiband()
  for (nm in names(.mb_targets(fx))) {
    g <- .mb_targets(fx)[[nm]]
    rs <- if (nm == "decim") "average" else "near"
    on <- .mb_warped(fx, g, rs, coalesce = TRUE)$value
    off <- .mb_warped(fx, g, rs, coalesce = FALSE)$value
    expect_identical(dim(on), c(fx$nb, g@dims[["y"]], g@dims[["x"]]))
    expect_equal(on, off, tolerance = 0, label = nm)
  }
  # the crop is a plain window of each band
  crop <- .mb_warped(fx, .mb_targets(fx)$crop)$value
  for (b in seq_len(fx$nb)) {
    expect_equal(crop[b, , ], unclass(fx$vals[[b]])[6:30, 11:45],
                 tolerance = 1e-6, ignore_attr = TRUE)
  }
})

test_that("warps that differ in grid or resampling stay per band", {
  fx <- fixture_multiband()
  tg <- .mb_targets(fx)
  g <- graph_new()
  w1 <- align_to(lazy_source(fx$path, band = 1L, graph = g), tg$crop)
  w2 <- align_to(lazy_source(fx$path, band = 2L, graph = g), tg$crop,
                 resampling = "bilinear")
  p <- plan_lazy(lazy_stack(list(w1, w2), along = "band"))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "warp"), 2L)
})

test_that("distributed execution matches memory on collapsed warps", {
  skip_on_cran()
  fx <- fixture_multiband()
  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 200)
  on.exit(options(old), add = TRUE)
  for (nm in c("crop", "shift")) {
    ds <- lazy_dataset(fx$path, .mb_targets(fx)[[nm]])
    lr <- reduce_over(stack_bands(ds), function(x, dims)
      g_sum(x * 0.25, dims = dims, nan_rm = FALSE), over = "band")
    p <- plan_lazy(lr)
    expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-6,
                 label = nm)
    expect_equal(collect(stack_bands(ds), distributed = TRUE),
                 collect(stack_bands(ds), distributed = FALSE),
                 tolerance = 0, ignore_attr = TRUE, label = nm)
  }
})

test_that("a band-interleaved file keeps its per-band warps", {
  # each band is its own run of bytes, so per-band tasks over the pool
  # stay the read shape (design/gdal-multiband-fanout.md)
  fx <- fixture_multiband()
  f <- withr::local_tempfile(fileext = ".tif")
  gdalraster::translate(fx$path, f, cl_arg = c("-co", "INTERLEAVE=BAND"),
                        quiet = TRUE)
  expect_false(.bands_share_blocks(f))
  expect_true(.bands_share_blocks(fx$path))
  ds <- lazy_dataset(f, .mb_targets(fx)$crop)
  p <- plan_lazy(stack_bands(ds))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "warp"), fx$nb)
})

# lazy_map() over a dataset applies one elementwise fn per band, so the
# band stack's parents are maps, not reads. The collapse composes the
# (chain of) identical maps into one map over the collapsed read.
test_that("a per-band map chain over one file collapses into one read", {
  fx <- fixture_multiband()
  tg <- .mb_targets(fx)$crop
  build <- function(coalesce) {
    old <- options(garry.read_coalesce = coalesce)
    on.exit(options(old), add = TRUE)
    ds <- lazy_map(lazy_dataset(fx$path, tg), fn = function(x) x * 2 + 1)
    ds <- lazy_map(ds, fn = function(x) sqrt(x), dtype = "f32")
    p <- plan_lazy(stack_bands(ds))
    list(plan = p, value = execute_plan(p))
  }
  on <- build(TRUE)
  kinds <- vapply(on$plan@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "warp"), 1L)
  w <- graph_get(on$plan@graph, on$plan@stages[[which(kinds == "warp")]]@members[[1L]])
  expect_identical(w@bands, seq_len(fx$nb))
  expect_equal(on$value, build(FALSE)$value, tolerance = 0)
  expect_equal(on$value[3, , ], sqrt(unclass(fx$vals[[3]])[6:30, 11:45] * 2 + 1),
               tolerance = 1e-6, ignore_attr = TRUE)
})

test_that("maps that differ per band, or a band-interleaved file, stay per band", {
  fx <- fixture_multiband()
  tg <- .mb_targets(fx)$crop
  ds <- lazy_dataset(fx$path, tg)
  part <- lazy_map(ds, fn = function(x) x + 1, bands = c("b1", "b2"))
  p <- plan_lazy(stack_bands(part))
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "warp"), fx$nb)
  f <- withr::local_tempfile(fileext = ".tif")
  gdalraster::translate(fx$path, f, cl_arg = c("-co", "INTERLEAVE=BAND"),
                        quiet = TRUE)
  p2 <- plan_lazy(stack_bands(lazy_map(lazy_dataset(f, tg), fn = function(x) x + 1)))
  kinds2 <- vapply(p2@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds2 == "warp"), fx$nb)
})

test_that("a graph rewritten by a hoist still imports into another graph", {
  fx <- fixture_multiband()
  tg <- .mb_targets(fx)$crop
  x <- stack_bands(lazy_map(lazy_dataset(fx$path, tg), fn = function(v) v * 2))
  first <- collect(x, distributed = FALSE) # rewrites x's graph in place
  y <- stack_bands(lazy_dataset(fx$path, tg)) # another graph, same grid
  z <- y + x # imports x's rewritten subgraph into y's graph
  expect_equal(collect(z, distributed = FALSE), first * 1.5, tolerance = 1e-6)
})

test_that(".topo_order keeps ascending ids and puts late parents first", {
  g <- graph_new()
  a <- graph_add(g, SourceNode, parents = integer(0),
                 grid = grid_spec("EPSG:32632", c(0, 0, 10, 10), res = 1),
                 path = "x.tif", band = 1L, nodata = numeric(0),
                 block_dim = c(10L, 10L), open_options = character(0))
  ga <- graph_get(g, a)@grid
  b <- graph_add(g, MapNode, parents = a, grid = ga, fn = identity)
  c2 <- graph_add(g, MapNode, parents = b, grid = ga, fn = identity)
  expect_identical(.topo_order(g, c(c2, a, b)), c(a, b, c2))
  # rewrite b in place over a new parent d (larger id)
  d <- graph_add(g, MapNode, parents = a, grid = ga, fn = identity)
  graph_replace(g, b, MapNode(id = b, parents = d, grid = ga, fn = identity))
  expect_identical(.topo_order(g, c(a, b, c2, d)), c(a, d, b, c2))
})
