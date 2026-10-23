# Edge chunks grown to the modal chunk shape (garry.pad_edge_chunks):
# the daemon pads an edge chunk's inputs with nodata, runs the stage's
# modal kernel and crops the outputs. Results must equal the edge
# chunks run at their own shapes.

test_that(".sv_grow and .sv_crop pad with nodata and invert", {
  set.seed(4)
  for (gdt in c("f32", "f64")) {
    es <- if (gdt == "f64") 8L else 4L
    for (d in list(c(5L, 3L), c(2L, 5L, 3L))) {
      v <- structure(
        writeBin(rnorm(prod(d)), raw(), size = es),
        gdim = d,
        gdt = gdt
      )
      g <- garry:::.sv_grow(v, c(2L, 1L))
      n <- length(d)
      expect_identical(
        as.integer(garry:::.sv_dim(g))[n - 1:0],
        d[n - 1:0] + c(2L, 1L)
      )
      a <- garry:::.sv_materialise(g)
      # the old cells sit at the top left; the new ones are NaN
      old <- garry:::.sv_materialise(v)
      if (n == 2L) {
        expect_identical(a[1:5, 1:3], old)
        expect_true(all(is.nan(a[6:7, ])) && all(is.nan(a[, 4])))
      } else {
        expect_identical(a[, 1:5, 1:3], old)
        expect_true(all(is.nan(a[, 6:7, ])) && all(is.nan(a[,, 4])))
      }
      expect_identical(garry:::.sv_crop(g, c(2L, 1L)), v)
    }
  }
  # R values (integer stores) pad with NA, which g_upload makes 0
  m <- matrix(1:15, 5L, 3L)
  gm <- garry:::.sv_grow(m, c(1L, 2L))
  expect_identical(dim(gm), c(6L, 5L))
  expect_true(all(is.na(gm[6, ])) && all(is.na(gm[, 4:5])))
  expect_identical(garry:::.sv_crop(gm, c(1L, 2L)), m)
  expect_identical(garry:::.sv_crop(list(a = gm), c(1L, 2L)), list(a = m))
})

test_that("grown edge chunks equal edge chunks run at their own shape", {
  local_pools(2, 2)
  g <- graph_new()
  a <- lazy_source(fixture_gradient_f32(), graph = g) # 60 x 40
  # a focal stage (halo ring beyond the raster's edge), a robust Kalman
  # smoother (strips) and a plain map, on 19 x 19 chunks: right, bottom
  # and corner edge chunks of three other shapes
  f <- focal_map(a, fn = function(sh) Reduce(`+`, sh) / 9, radius = 1L)
  steps <- lapply(1:5, function(t) {
    v <- a * (1 + t / 10)
    if (t %% 2 == 0) {
      v <- lazy_map(v, dtype = "f32", fn = function(z) {
        g_ifelse(z > 30 & z < 40, NaN, z)
      })
    }
    v
  })
  sm <- kalman_smooth(
    lazy_stack(steps, along = "t"),
    1,
    0.1,
    1.4,
    robust_iters = 1L
  )
  run <- function(pad) {
    withr::local_options(
      garry.pad_edge_chunks = pad,
      garry.chunk_target_px = 375
    )
    list(
      focal = collect(f, distributed = TRUE),
      mean = collect(sm$mean, distributed = TRUE),
      sd = collect(sm$sd, distributed = TRUE),
      map = collect(a * 2 + 1, distributed = TRUE)
    )
  }
  withr::with_options(list(garry.chunk_target_px = 375), {
    p <- collect(f, plan_only = TRUE)
  })
  shapes <- unlist(lapply(p@stages, function(s) {
    if (s@kind == "compute") chunk_iter(s@chunks)$shape_id
  }))
  expect_true(all(c("right", "bottom", "corner") %in% shapes))
  expect_identical(run(TRUE), run(FALSE))
  # a quantized write: the cropped integer outputs land identically
  p1 <- withr::local_tempfile(fileext = ".tif")
  p2 <- withr::local_tempfile(fileext = ".tif")
  withr::with_options(
    list(garry.pad_edge_chunks = TRUE, garry.chunk_target_px = 375),
    write_tif(
      f,
      p1,
      dtype = "i16",
      scale = 0.01,
      nodata = -32768,
      distributed = TRUE
    )
  )
  withr::with_options(
    list(garry.pad_edge_chunks = FALSE, garry.chunk_target_px = 375),
    write_tif(
      f,
      p2,
      dtype = "i16",
      scale = 0.01,
      nodata = -32768,
      distributed = TRUE
    )
  )
  expect_identical(collect(lazy_source(p1)), collect(lazy_source(p2)))
})

test_that("spatial reductions are not grown at edge chunks", {
  # Padding a reduction's partials with nodata would poison a sum taken
  # without nan_rm (rules placement keeps the reduction off the reads)
  local_pools(2, 2)
  withr::local_options(garry.chunk_target_px = 375, garry.placement = "rules")
  g <- graph_new()
  a <- lazy_source(fixture_gradient_f32(), graph = g) # no nodata
  for (r in list(
    reduce_over(a * 1, "sum", c("x", "y"), nan_rm = FALSE),
    reduce_over(a * 1, "mean", c("x", "y"), nan_rm = FALSE),
    reduce_over(a * 1, "count", c("x", "y"))
  )) {
    got <- collect(r, distributed = TRUE)
    expect_false(anyNA(got))
    expect_equal(
      got,
      collect(r, distributed = FALSE),
      tolerance = 1e-6,
      ignore_attr = TRUE
    )
  }
})
