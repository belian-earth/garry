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
  # R values pad with what their dtype holds beyond the raster
  m <- matrix(1:15, 5L, 3L)
  gm <- garry:::.sv_grow(m, c(1L, 2L), "i16")
  expect_identical(dim(gm), c(6L, 5L))
  expect_true(all(gm[6, ] == 0) && all(gm[, 4:5] == 0))
  expect_equal(garry:::.sv_crop(gm, c(1L, 2L)), m)
  expect_equal(garry:::.sv_crop(list(a = gm), c(1L, 2L)), list(a = m))
  expect_true(all(is.nan(garry:::.sv_grow(m + 0.5, c(1L, 2L), "f64")[6, ])))
  # values that are not planes pass through
  expect_error(garry:::.sv_grow(3.5, c(1L, 2L), "f32"), class = "garry_kernel_error")
  expect_error(garry:::.sv_crop(1:4, c(1L, 2L)), class = "garry_kernel_error")
})

# A kernel on grown edge chunks is built for the modal shape alone, and a task
# meeting any other fails (.program_miss()), so a clean pooled run on a stage
# that grows shows the padding fired on its daemon.
local({
  local_pools(2, 1)

  # The 3 x 3 mean of the gradient plane: its centre, NaN off the raster.
  mean3 <- .fixture_values(60, 40)
  mean3[c(1L, 40L), ] <- NaN
  mean3[, c(1L, 60L)] <- NaN

  test_that("grown edge chunks equal edge chunks run at their own shape", {
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
          g_ifelse(z > 1000 & z < 1500, NaN, z)
        })
      }
      v
    })
    .expect_partial_nan(collect(steps[[2L]], distributed = FALSE))
    sm <- kalman_smooth(
      lazy_stack(steps, along = "t"),
      1,
      0.1,
      1.4,
      robust_iters = 1L
    )
    map <- a * 2 + 1
    # mean and sd together: one stage, one kernel for each shape
    run <- function(pad) {
      withr::local_options(
        garry.pad_edge_chunks = pad,
        garry.chunk_target_px = 375
      )
      c(
        list(
          focal = collect(f, distributed = TRUE),
          map = collect(map, distributed = TRUE)
        ),
        collect(list(mean = sm$mean, sd = sm$sd), distributed = TRUE)
      )
    }
    withr::with_options(list(garry.chunk_target_px = 375), {
      p <- collect(f, plan_only = TRUE)
    })
    stage <- Filter(function(s) s@kind == "compute", p@stages)[[1L]]
    expect_true(all(c("right", "bottom", "corner") %in% chunk_iter(stage@chunks)$shape_id))
    expect_true(withr::with_options(
      list(garry.pad_edge_chunks = TRUE),
      garry:::.stage_grows_edges(p@graph, stage)
    ))
    grown <- run(TRUE)
    expect_identical(grown, run(FALSE))
    .expect_cells(unclass(grown$focal), mean3)
    .expect_cells(unclass(grown$map), .fixture_values(60, 40) * 2 + 1)
    # a quantized write: the cropped integer outputs land in place
    withr::local_options(garry.pad_edge_chunks = TRUE)
    expect_written(f, mean3 * 2, "i16", legs = list(.leg()), scale = 0.5, nodata = -32768, px = 375)
  })

  test_that("spatial reductions are not grown at edge chunks", {
    # Padding a reduction's partials with nodata would poison a sum taken
    # without nan_rm, and a count would count the padding (rules placement
    # keeps the reduction off the reads)
    withr::local_options(garry.placement = "rules")
    a <- lazy_source(fixture_gradient_f32()) # no nodata
    legs <- list(.leg())
    expect_plan(reduce_over(a * 1, "sum", c("x", "y"), nan_rm = FALSE),
                sum(.fixture_values(60, 40)), "f32", legs = legs, px = 375)
    expect_plan(reduce_over(a * 1, "count", c("x", "y")), 2400, "i32", legs = legs, px = 375)
  })

  test_that("fused read windows grow to the modal window", {
    skip_on_os("mac") # fused-on-reader hang on macOS ARM (test-compute-on-read)
    # rules placement fuses the mask chain onto its reads; small read
    # windows give the source stage a bottom edge window
    withr::local_options(
      garry.chunk_target_px = 375,
      garry.read_target_px = 1000,
      garry.placement = "rules"
    )
    f <- fixture_gradient_f32()
    qa <- lazy_source(f)
    mask <- focal_map(
      lazy_map(qa, dtype = "f32", fn = function(x) g_cast(x > 0.5, "f32")),
      radius = 1L,
      fn = function(sh) Reduce(`*`, sh)
    )
    b <- lazy_source(f, graph = qa@graph)
    masked <- lazy_map(b, mask, dtype = "f32", fn = function(x, m) {
      g_ifelse(m > 0.5, NaN, x)
    })
    out <- reduce_over(
      lazy_stack(list(masked, masked * 2)),
      "median",
      "t",
      nan_rm = TRUE
    )
    p <- plan_lazy(out)
    src_shapes <- unlist(lapply(p@stages, function(s) {
      if (s@kind == "source_read") chunk_iter(s@chunks)$shape_id
    }))
    expect_true("bottom" %in% src_shapes)
    run <- function(pad) {
      withr::local_options(garry.pad_edge_chunks = pad)
      collect(out, distributed = TRUE)
    }
    grown <- run(TRUE)
    expect_identical(grown, run(FALSE))
    # every cell passes, so the mask holds off the edge ring, where its window
    # leaves the raster: the median of (v, 2v) there, NaN inside
    want <- .fixture_values(60, 40) * 1.5
    want[2:39, 2:59] <- NaN
    .expect_cells(unclass(grown), want)
  })
})
