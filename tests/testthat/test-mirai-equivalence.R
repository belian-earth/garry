# Decision D16 lock: the distributed executor returns what plain R and
# gdalwarp say a plan is, on the shapes that need coarse reads or a warp.
# test-route-dtype.R holds the golden pipeline shapes, and that warm-up
# lands in the compute pool's cache. Distributed execution requires the
# garry pools: a plain mirai::daemons() pool is not silently used.

local({
  local_pools(2, 1)
  withr::local_options(garry.chunk_target_px = 400)
  f <- fixture_gradient_f32()

  test_that("the benchmark shape writes what plain R computes", {
    # Coarse whole-window reads + zero-copy consumer slicing (the store
    # skips the producer-side split entirely), per-band fused stages,
    # band-stack join, multiband write sink.
    withr::local_options(garry.read_target_px = 4e3)
    composite_of <- function(off) {
      masked <- lapply(c(0, off), function(o) {
        lazy_map(lazy_source(f) + o, dtype = "f32",
                 fn = function(x) g_ifelse(x > 2600, NaN, x))
      })
      reduce_over(lazy_stack(masked), "median", "t", nan_rm = TRUE)
    }
    # the median of what the mask leaves in the two slices
    composite_want <- function(off) {
      a <- .fixture_values(60, 40)
      b <- a + off
      a[a > 2600] <- NaN
      b[b > 2600] <- NaN
      ifelse(is.nan(a), b, ifelse(is.nan(b), a, (a + b) / 2))
    }
    out <- lazy_stack(list(composite_of(4), composite_of(8)), along = "band")
    path <- withr::local_tempfile(fileext = ".tif")
    execute_plan_mirai(plan_lazy(out), path = path, nodata = -9999)
    for (b in 1:2) {
      got <- gdal_read_window(path, b, 0L, 0L, 60L, 40L, nodata = -9999)
      .expect_cells(unclass(got), composite_want(c(4, 8)[[b]]))
    }
  })

  test_that("a distributed warp pipeline computes what gdalwarp lands", {
    g <- gdal_grid_spec(f)$grid
    b <- gdalraster::transform_bounds(g@extent, g@crs, "EPSG:4326")
    target <- grid_spec("EPSG:4326", extent = b, dims = c(61L, 43L))
    got <- execute_plan_mirai(plan_lazy(align_to(lazy_source(f), target) * 2))
    .expect_cells(unclass(got), .geo_oracle(f, target) * 2)
  })
})

test_that("no daemons gives the structured scheduler error", {
  p <- plan_lazy(lazy_source(fixture_gradient_f32()) * 2)
  expect_error(execute_plan_mirai(p), class = "garry_scheduler_error")
})

test_that("a plain mirai pool is NOT used; garry pools are required", {
  mirai::daemons(2) # a plain default pool, not garry's split
  on.exit(mirai::daemons(0), add = TRUE)
  p <- plan_lazy(lazy_source(fixture_gradient_f32()) + 1)
  expect_error(execute_plan_mirai(p), class = "garry_scheduler_error")
})
