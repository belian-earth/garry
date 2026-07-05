# Decision D17 lock: stacks are (t, y, x) chunks, StackNode fuses, and
# temporal reductions run chunk-locally (median included, per D12).

skip_if_not_installed("anvl")

# Three-date fixtures on one grid, deterministic values.
.stack_fixtures <- function() {
  paths <- vapply(1:3, function(i) {
    f <- file.path(tempdir(), sprintf("garry-fixture-t%d.tif", i))
    if (!file.exists(f)) {
      ds <- gdalraster::create("GTiff", f, 50, 40, 1, "Float32",
                               return_obj = TRUE)
      ds$setGeoTransform(c(0, 10, 0, 400, 0, -10))
      ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
      set.seed(100 + i)
      m <- matrix(runif(50 * 40), 40, 50) + i          # layer-distinct
      if (i == 2) m[5:8, 10:12] <- NaN                 # nodata patch
      ds$write(1, 0, 0, 50, 40, as.numeric(t(m)))
      ds$close()
    }
    f
  }, character(1))
  paths
}

.read_layers <- function(paths) {
  lapply(paths, function(f) gdal_read_window(f, 1L, 0L, 0L, 50L, 40L))
}

test_that("collect of a raw stack returns the (t, y, x) array", {
  paths <- .stack_fixtures()
  st <- lazy_stack(lapply(paths, lazy_source))
  expect_identical(unname(st@grid@dims), c(50L, 40L, 3L))
  expect_identical(names(st@grid@dims), c("x", "y", "t"))

  got <- collect(st)
  layers <- .read_layers(paths)
  expect_identical(dim(got), c(3L, 40L, 50L))
  for (i in 1:3) {
    expect_equal(got[i, , ], layers[[i]], tolerance = 1e-6,
                 label = paste("layer", i))
  }
})

test_that("temporal median and mean match terra::app and R apply", {
  skip_if_not_installed("terra")
  paths <- .stack_fixtures()
  st <- lazy_stack(lapply(paths, lazy_source))
  layers <- .read_layers(paths)
  arr <- g_stack(layers)

  med <- collect(reduce_over(st, "median", "t", nan_rm = TRUE))
  want_med <- apply(arr, c(2, 3), function(v) {
    m <- median(v, na.rm = TRUE); if (is.na(m)) NaN else m
  })
  expect_equal(med, want_med, tolerance = 1e-6)

  r <- terra::rast(paths)
  tmed <- as.matrix(terra::app(r, median, na.rm = TRUE), wide = TRUE)
  ok <- !is.nan(want_med)
  expect_equal(med[ok], tmed[ok], tolerance = 1e-6)

  mn <- collect(reduce_over(st, "mean", "t", nan_rm = TRUE))
  want_mn <- apply(arr, c(2, 3), function(v) mean(v, na.rm = TRUE))
  expect_equal(mn, want_mn, tolerance = 1e-6)
})

test_that("stack fuses with the temporal reduce into one compute stage", {
  paths <- .stack_fixtures()
  st <- lazy_stack(lapply(paths, lazy_source))
  med <- reduce_over(st, "median", "t")
  p <- collect(med, plan_only = TRUE)
  kinds <- vapply(p@stages, function(s) s@kind, character(1))
  expect_identical(sum(kinds == "compute"), 1L)
  compute <- p@stages[[which(kinds == "compute")]]
  expect_length(compute@members, 2L)   # stack + reduce fused
})

test_that("masked median composite matches the R reference", {
  # The benchmark shape in miniature: per-layer mask (threshold plays the
  # role of an Fmask decode) -> stack -> nan_rm median.
  paths <- .stack_fixtures()
  layers <- .read_layers(paths)

  srcs <- lapply(paths, lazy_source)
  # Mask via a MapNode closure (the closure runs traced under jit).
  masked <- lapply(srcs, function(s) {
    lr <- s
    id <- graph_add(lr@graph, MapNode, parents = lr@node_id,
                    grid = lr@grid,
                    fn = function(x) {
                      frac <- x - g_cast(x, "i32")
                      g_ifelse(frac > 0.8, NaN, x)
                    })
    LazyRaster(graph = lr@graph, node_id = id, grid = lr@grid)
  })
  st <- lazy_stack(masked)
  med <- reduce_over(st, "median", "t", nan_rm = TRUE)

  old <- options(garry.chunk_target_px = 300)
  on.exit(options(old))
  got <- collect(med)

  ref_layers <- lapply(layers, function(m) {
    frac <- m - trunc(m)
    m[!is.nan(m) & frac > 0.8] <- NaN
    m
  })
  arr <- g_stack(ref_layers)
  want <- apply(arr, c(2, 3), function(v) {
    md <- median(v, na.rm = TRUE); if (is.na(md)) NaN else md
  })
  expect_identical(is.nan(got), is.nan(want))
  ok <- !is.nan(want)
  expect_equal(got[ok], want[ok], tolerance = 1e-5)
})

test_that("stacks are chunk-invariant", {
  paths <- .stack_fixtures()
  st <- lazy_stack(lapply(paths, lazy_source))
  med <- reduce_over(st, "median", "t", nan_rm = TRUE)

  run <- function(px) {
    old <- options(garry.chunk_target_px = px)
    on.exit(options(old))
    collect(med)
  }
  whole <- run(1e6)
  for (px in c(13 * 11, 23 * 17)) {
    got <- run(px)
    expect_identical(is.nan(got), is.nan(whole))
    ok <- !is.nan(whole)
    expect_equal(got[ok], whole[ok], tolerance = 1e-7, label = px)
  }
})

test_that("distributed stacks match single-threaded", {
  skip_if_not_installed("mirai")
  paths <- .stack_fixtures()
  st <- lazy_stack(lapply(paths, lazy_source))
  med <- reduce_over(st, "median", "t", nan_rm = TRUE)
  p <- plan_lazy(med)

  mirai::daemons(2)
  on.exit(mirai::daemons(0), add = TRUE)
  old <- options(garry.chunk_target_px = 300)
  on.exit(options(old), add = TRUE)

  single <- execute_plan(p)
  dist <- execute_plan_mirai(p)
  expect_identical(is.nan(dist), is.nan(single))
  ok <- !is.nan(single)
  expect_equal(dist[ok], single[ok], tolerance = 1e-12)
})

test_that("mismatched grids are rejected", {
  paths <- .stack_fixtures()
  a <- lazy_source(paths[[1]])
  b <- lazy_source(fixture_gradient_f32())
  expect_error(lazy_stack(list(a, b)), "same grid")
})
