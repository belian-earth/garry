# Decision D16 lock: the distributed executor produces IDENTICAL results
# to the single-threaded executor on every golden pipeline shape (same
# Plan, same kernels, two schedulers).

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")

test_that("distributed == single-threaded across pipeline shapes", {
  # The current package must be installed for daemons to load it.
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")

  mirai::daemons(2)
  on.exit(mirai::daemons(0), add = TRUE)

  old <- options(garry.chunk_target_px = 400)   # force many chunks
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  fi <- fixture_i16_nodata()

  pipelines <- list(
    map      = local({ a <- lazy_source(f); a * 2 + 1 }),
    ndvi     = local({
      a <- lazy_source(f); b <- lazy_source(f)
      (a - b / 2) / (a + b / 2)
    }),
    focal    = local({
      a <- lazy_source(f)
      focal(a + 1, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
    }),
    stacked  = local({
      a <- lazy_source(f)
      s9 <- function(sh) Reduce(`+`, sh)
      focal(focal(a, s9, 1L), s9, 2L)
    }),
    reduce   = local({
      a <- lazy_source(fi)
      reduce_over(a * 2, "mean", c("x", "y"), nan_rm = TRUE)
    })
  )

  stores <- c("rds",
              if (requireNamespace("mori", quietly = TRUE)) "mori")
  for (nm in names(pipelines)) {
    p <- plan_lazy(pipelines[[nm]])
    single <- execute_plan(p)
    for (st in stores) {
      old_st <- options(garry.store = st)
      dist <- execute_plan_mirai(p)
      options(old_st)
      expect_equal(dist, single, tolerance = 1e-12,
                   label = paste(nm, st))
    }
  }
})

test_that("mori store matches rds store on the benchmark shape", {
  # Coarse whole-window reads + zero-copy consumer slicing (the mori
  # path skips the producer-side split entirely), per-band fused
  # stages, band-stack join, multiband write sink.
  skip_if_not_installed("mori")
  skip_if(!requireNamespace("garry", quietly = TRUE))
  mirai::daemons(2)
  on.exit(mirai::daemons(0), add = TRUE)
  old <- options(garry.chunk_target_px = 400, garry.read_target_px = 4e3)
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  composite_of <- function(off) {
    masked <- lapply(c(0, off), function(o) {
      lazy_map(lazy_source(f) + o, dtype = "f32",
               fn = function(x) g_ifelse(x > 2600, NaN, x))
    })
    reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
  }
  out <- lazy_stack(list(composite_of(4), composite_of(8)),
                    along = "band")
  p <- plan_lazy(out)

  run_with <- function(st, path) {
    old_st <- options(garry.store = st)
    on.exit(options(old_st), add = TRUE)
    execute_plan_mirai(p, path = path, nodata = -9999)
    lapply(1:2, function(b)
      gdal_read_window(path, b, 0L, 0L, 60L, 40L))
  }
  v_rds <- run_with("rds", file.path(tempdir(), "eq-rds.tif"))
  v_shm <- run_with("mori", file.path(tempdir(), "eq-shm.tif"))
  expect_equal(v_shm, v_rds, tolerance = 1e-12)
})

test_that("distributed warp pipeline and write sink match", {
  skip_if(!requireNamespace("garry", quietly = TRUE))
  mirai::daemons(2)
  on.exit(mirai::daemons(0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  g <- gdal_grid_spec(f)$grid
  b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
  target <- grid_spec("EPSG:4326", extent = b, dims = c(61L, 43L))

  a <- lazy_source(f)
  expr <- align(a, target) * 2
  p <- plan_lazy(expr)
  single <- execute_plan(p)
  dist <- execute_plan_mirai(p)
  expect_identical(is.nan(dist), is.nan(single))
  ok <- !is.nan(single)
  expect_equal(dist[ok], single[ok], tolerance = 1e-12)

  # Write path through the distributed executor.
  out1 <- tempfile(fileext = ".tif")
  out2 <- tempfile(fileext = ".tif")
  a2 <- lazy_source(f)
  expr2 <- a2 * 3 - 2
  p2 <- plan_lazy(expr2)
  execute_plan(p2, path = out1)
  execute_plan_mirai(p2, path = out2)
  expect_identical(gdal_read_window(out2, 1L, 0L, 0L, 60L, 40L),
                   gdal_read_window(out1, 1L, 0L, 0L, 60L, 40L))
})

test_that("no daemons gives the structured scheduler error", {
  f <- fixture_gradient_f32()
  a <- lazy_source(f)
  p <- plan_lazy(a * 2)
  expect_error(execute_plan_mirai(p), class = "garry_scheduler_error")
})
