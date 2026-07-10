# Phase 12c: raw f32 store payloads (D19-D21). Gates: the sv helper
# algebra matches the matrix path exactly; distributed execution (raw f32
# mori store) is identical to the single-threaded executor (which always
# uses R matrices, the correctness oracle) across map / focal / median /
# global-reduce / multiband-sink pipelines; non-f32 sources stay on the
# matrix path.

test_that("sv helpers mirror matrix slicing exactly", {
  set.seed(3)
  m <- matrix(rnorm(35 * 52), 35, 52)
  m[sample(length(m), 40)] <- NaN
  f32 <- function(x) {   # reference double -> f32 -> double rounding
    matrix(readBin(writeBin(as.numeric(t(x)), raw(), size = 4L),
                   numeric(), length(x), size = 4L),
           nrow(x), byrow = TRUE)
  }
  sv <- garry:::.sv_from_vec(as.numeric(t(m)), 35L, 52L)
  expect_true(garry:::.sv_is(sv))
  expect_identical(garry:::.sv_dim(sv), c(35L, 52L))
  expect_identical(garry:::.sv_to_matrix(sv), f32(m))
  expect_identical(garry:::.sv_materialise(sv), f32(m))

  slc <- garry:::.sv_slicer(sv)
  p <- slc(4L, 9L, 17L, 21L)
  expect_identical(garry:::.sv_to_matrix(p), f32(m[5:21, 10:30]))

  tr <- garry:::.sv_trim(sv, 6L)
  expect_identical(garry:::.sv_to_matrix(tr), f32(m[7:29, 7:46]))
  expect_identical(garry:::.exec_trim(sv, 6L), tr)

  # zero-trim is the identity, not a copy of the payload
  expect_identical(garry:::.exec_trim(sv, 0L), sv)
})

test_that("distributed raw f32 store == single-threaded oracle", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  skip_if(!garry::.g_has_raw_upload(),
          "installed anvl lacks raw payload support")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)   # force many chunks
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  fi <- fixture_i16_nodata()
  pipelines <- list(
    map    = local({ a <- lazy_source(f); a * 2 + 1 }),
    focal  = local({
      a <- lazy_source(f)
      focal(a, radius = 1L, fn = function(sh) Reduce(`+`, sh))
    }),
    median = local({
      a <- lazy_source(f); b <- lazy_source(f)
      reduce_over(lazy_stack(list(a + 1, b * 2)), "median", "t",
                  nan_rm = TRUE)
    }),
    global = local({
      a <- lazy_source(f)
      reduce_over(a * 2, "mean", c("x", "y"), nan_rm = TRUE)
    }),
    i16    = local({ a <- lazy_source(fi); a + 0.5 })
  )
  for (nm in names(pipelines)) {
    p <- plan_lazy(pipelines[[nm]])
    single <- execute_plan(p)
    dist <- execute_plan_mirai(p)
    expect_equal(dist, single, tolerance = 1e-12, label = paste("dist", nm))
  }
})

test_that("distributed multiband sink streams to GTiff like the oracle", {
  skip_if_not_installed("anvl")
  skip_if_not_installed("mirai")
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  skip_if(!garry::.g_has_raw_upload(),
          "installed anvl lacks raw payload support")

  garry_daemons(2, 1)
  on.exit(garry_daemons(0, 0), add = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  f <- fixture_gradient_f32()
  bands <- lazy_stack(list(
    local({ a <- lazy_source(f); a * 2 }),
    local({ a <- lazy_source(f); a + 10 })
  ), along = "band")

  out_d <- tempfile(fileext = ".tif")
  collect(bands, path = out_d, distributed = TRUE)
  dist <- lapply(1:2, function(b) gdal_read_window(out_d, b, 0L, 0L, 60L, 40L))
  out_s <- tempfile(fileext = ".tif")
  collect(bands, path = out_s)
  single <- lapply(1:2, function(b) gdal_read_window(out_s, b, 0L, 0L, 60L, 40L))
  expect_equal(dist, single, tolerance = 1e-5)
})
