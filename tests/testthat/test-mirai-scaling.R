# Scaling smoke (slow; run on demand: GARRY_RUN_SCALING=1). Wall-clock
# assertions are environment-sensitive, so this is nightly/manual tier.

skip_if_not_installed("anvl")
skip_if_not_installed("mirai")
skip_if(!nzchar(Sys.getenv("GARRY_RUN_SCALING")),
        "set GARRY_RUN_SCALING=1 to run")

test_that("distributed execution scales on a compute-heavy pipeline", {
  # Big synthetic raster with a heavy fused stage.
  f <- file.path(tempdir(), "garry-scaling.tif")
  if (!file.exists(f)) {
    ds <- gdalraster::create("GTiff", f, 2000, 2000, 1, "Float32",
                             return_obj = TRUE)
    ds$setGeoTransform(c(0, 10, 0, 20000, 0, -10))
    ds$setProjection(gdalraster::srs_to_wkt("EPSG:3857"))
    set.seed(1)
    for (row0 in seq(0, 1999, by = 500))
      ds$write(1, 0, row0, 2000, 500, runif(2000 * 500))
    ds$close()
  }
  build <- function() {
    a <- lazy_source(f)
    s25 <- function(sh) Reduce(`+`, sh) / 25
    reduce_over(focal(focal(a, s25, 2L), s25, 2L), "mean", c("x", "y"))
  }
  old <- options(garry.chunk_target_px = 250000)
  on.exit(options(old), add = TRUE)
  p <- plan_lazy(build())

  time_with <- function(n) {
    mirai::daemons(n)
    on.exit(mirai::daemons(0), add = TRUE)
    # Warm daemons (jit compile) then time.
    invisible(execute_plan_mirai(p))
    system.time(execute_plan_mirai(p))[["elapsed"]]
  }
  t1 <- time_with(1)
  t2 <- time_with(2)
  t4 <- time_with(4)
  cat(sprintf("\nscaling: 1=%.2fs 2=%.2fs 4=%.2fs\n", t1, t2, t4))
  expect_lt(t2, t1 / (2 * 0.7) + 0.5)
  expect_lt(t4, t1 / (4 * 0.7) + 0.5)
})
