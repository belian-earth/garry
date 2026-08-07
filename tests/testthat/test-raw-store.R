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
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  skip_if(!garry::.g_has_raw_upload(),
          "installed anvl lacks raw payload support")

  local_pools(2, 1, gdal_config = TRUE)
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
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  skip_if(!garry::.g_has_raw_upload(),
          "installed anvl lacks raw payload support")

  local_pools(2, 1, gdal_config = TRUE)
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

# --- f64 store payloads (design/f64-store.md) -------------------------

test_that("f64 payloads round-trip the sv layer bit-exactly", {
  m <- matrix(c(1.5, -2.25, pi, exp(1), 1e-300, -0.125), 2, 3)
  v <- garry:::.sv_from_vec(as.numeric(t(m)), 2L, 3L, gdt = "f64")
  expect_identical(garry:::.sv_es(v), 8L)
  expect_identical(attr(v, "gdt"), "f64")
  expect_identical(garry:::.sv_to_matrix(v), m)
  expect_identical(garry:::.sv_materialise(v), m)

  # trim preserves dtype and bits
  mp <- matrix(rnorm(36), 6, 6)
  vp <- garry:::.sv_from_vec(as.numeric(t(mp)), 6L, 6L, gdt = "f64")
  tr <- garry:::.sv_trim(vp, 1L)
  expect_identical(attr(tr, "gdt"), "f64")
  expect_identical(garry:::.sv_to_matrix(tr), mp[2:5, 2:5])

  # producer-side slicing preserves dtype and bits
  slc <- garry:::.sv_slicer(vp)
  s1 <- slc(1L, 2L, 3L, 3L)
  expect_identical(attr(s1, "gdt"), "f64")
  expect_identical(garry:::.sv_to_matrix(s1), mp[2:4, 3:5])
})

test_that("f64 raw upload/download round-trips through anvl bit-exactly", {
  skip_if(!garry:::.g_has_raw_upload(), "no raw upload support")
  m <- matrix(c(1.5, -2.25, pi, 1e-300), 2, 2)
  v <- garry:::.sv_from_vec(as.numeric(t(m)), 2L, 2L, gdt = "f64")
  up <- g_upload_raw(unclass(v), "f64", garry:::.sv_dim(v))
  down <- g_download_raw(up)
  expect_identical(attr(down, "gdt"), "f64")
  expect_identical(garry:::.sv_to_matrix(down), m)
})

test_that("an f64 chain runs distributed bit-identically to the oracle", {
  f <- fixture_gradient_f32()
  # an f64 map chain feeding an f64 sink: with the f64 raw store the
  # distributed result must be BIT-identical to the all-doubles oracle
  a <- lazy_source(f)
  y <- lazy_map(a, dtype = "f64", fn = function(x) x * (1 / 3) + 1e-7)
  z <- reduce_over(lazy_stack(list(y, y * 2), along = "t"), "mean", "t",
                   nan_rm = TRUE)
  p <- plan_lazy(list(y = y, z = z))
  single <- execute_plan(p)

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)
  for (m in c("rules", "cost")) {
    old_m <- options(garry.placement = m)
    dist <- execute_plan_mirai(p)
    expect_identical(dist$y, single$y, label = paste("y", m))
    expect_identical(dist$z, single$z, label = paste("z", m))

    d <- withr::local_tempdir()
    execute_plan_mirai(p, path = d)
    got <- gdal_read_window(file.path(d, "y.tif"), 1L, 0, 0,
                            ncol(single$y), nrow(single$y))
    expect_equal(got, single$y, tolerance = 0, label = paste("file", m))
    options(old_m)
  }
})
