# Decision D10 lock: hand-traced golden plans. Changing planner output
# means consciously editing these literals.

.stage_sig <- function(plan) {
  lapply(plan@stages, function(s) {
    list(kind = s@kind, members = as.integer(s@members),
         halo = as.integer(s@halo), inputs = as.integer(s@inputs))
  })
}

test_that("golden: two-source NDVI fuses into one compute stage", {
  a <- lazy_source("nir.tif")
  b <- lazy_source("red.tif")
  ndvi <- (a - b) / (a + b)
  p <- collect(ndvi, plan_only = TRUE)

  expect_identical(.stage_sig(p), list(
    list(kind = "source_read", members = 1L, halo = 0L, inputs = integer(0)),
    list(kind = "source_read", members = 2L, halo = 0L, inputs = integer(0)),
    list(kind = "compute", members = c(3L, 4L, 5L), halo = 0L,
         inputs = c(1L, 2L))
  ))
  expect_identical(p@sink, 3L)
})

test_that("golden: source -> map -> focal -> reduce(mean over x,y)", {
  a <- lazy_source("x.tif")
  f <- focal(a + 1, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  r <- reduce_over(f, "mean", c("x", "y"))
  p <- collect(r, plan_only = TRUE)

  expect_identical(.stage_sig(p), list(
    list(kind = "source_read", members = 1L, halo = 1L, inputs = integer(0)),
    list(kind = "compute", members = c(2L, 3L), halo = 1L, inputs = 1L),
    list(kind = "reduce_partial", members = 4L, halo = 0L, inputs = 2L),
    list(kind = "reduce_combine", members = 4L, halo = 0L, inputs = 3L)
  ))
  expect_identical(p@sink, 4L)
})

test_that("golden: cross-graph add plans like a shared-graph add", {
  a <- lazy_source("x.tif")
  b <- lazy_source("y.tif")            # separate graph: auto-merge (D6)
  p <- collect(a + b, plan_only = TRUE)

  expect_identical(.stage_sig(p), list(
    list(kind = "source_read", members = 1L, halo = 0L, inputs = integer(0)),
    list(kind = "source_read", members = 2L, halo = 0L, inputs = integer(0)),
    list(kind = "compute", members = 3L, halo = 0L, inputs = c(1L, 2L))
  ))
})

test_that("golden: align -> map produces a warp barrier stage", {
  a <- lazy_source("x.tif")
  target <- grid_spec("EPSG:4326", extent = c(0, -100, 100, 0),
                      dims = c(50L, 50L))
  m <- align(a, target) * 2
  p <- collect(m, plan_only = TRUE)

  expect_identical(.stage_sig(p), list(
    list(kind = "source_read", members = 1L, halo = 0L, inputs = integer(0)),
    list(kind = "warp", members = 2L, halo = 0L, inputs = 1L),
    list(kind = "compute", members = 3L, halo = 0L, inputs = 2L)
  ))
  expect_true(grid_equal(p@stages[[2L]]@grid, target))
})

test_that("golden: diamond on one source stays in one compute stage", {
  a <- lazy_source("x.tif")
  d <- (a + 1) * (a * 2)
  p <- collect(d, plan_only = TRUE)
  expect_identical(.stage_sig(p), list(
    list(kind = "source_read", members = 1L, halo = 0L, inputs = integer(0)),
    list(kind = "compute", members = c(2L, 3L, 4L), halo = 0L, inputs = 1L)
  ))
})
