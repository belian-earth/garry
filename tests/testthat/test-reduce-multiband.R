# Multivariate temporal reducers (geomedian / medoid) over a
# (band, t, y, x) cube: 4D stack grid algebra; both reducers match
# brute-force pure-R references at every pixel including NaN-masked
# timesteps; the medoid returns an observed spectrum; distributed ==
# single-threaded.


.mb_cube <- function() {
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  # 4 dates x 2 bands with structure; date 3 masked in a region (both
  # bands, as a shared cloud mask would)
  hole <- function(x) lazy_map(x, dtype = "f32",
                               fn = function(v) g_ifelse(v > 0.6, NaN, v))
  b1 <- lazy_stack(list(t1 = s(), t2 = s() * 1.1, t3 = hole(s() * 3),
                        t4 = s() * 0.9), along = "t")
  b2 <- lazy_stack(list(t1 = s() + 1, t2 = s() * 2, t3 = hole(s() * 5),
                        t4 = s() * 1.5), along = "t")
  lazy_stack(list(A = b1, B = b2), along = "band")
}

.ref_wz <- function(Y, iters = 12L, eps = 1e-7) {
  # Y: (band, t) with NaN columns for masked dates
  ok <- colSums(is.na(Y)) == 0L
  if (!any(ok)) return(rep(NaN, nrow(Y)))
  Yv <- Y[, ok, drop = FALSE]
  m <- rowMeans(Yv)
  for (k in seq_len(iters)) {
    d <- sqrt(colSums((Yv - m)^2))
    w <- 1 / (d + eps)
    m <- as.vector(Yv %*% w) / sum(w)
  }
  m
}

test_that("stacking cubes along band builds a labelled 4D grid", {
  cube <- .mb_cube()
  expect_identical(names(cube@grid@dims), c("x", "y", "band", "t"))
  expect_identical(unname(cube@grid@dims[c("band", "t")]), c(2L, 4L))
  expect_identical(cube@grid@labels$t, c("t1", "t2", "t3", "t4"))
  expect_identical(cube@grid@labels$band, c("A", "B"))

  # stacking along a dim the parents already carry is an error
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  st <- lazy_stack(list(s(), s() * 2), along = "t")
  expect_error(lazy_stack(list(st, st * 2), along = "t"), "existing dim")
})

test_that("geomedian matches the pure-R Weiszfeld at every pixel", {
  cube <- .mb_cube()
  got <- execute_plan(plan_lazy(reduce_over(cube, geomedian(), over = "t")))
  raw <- execute_plan(plan_lazy(cube))          # (band, t, y, x)
  expect_identical(dim(got), dim(raw)[c(1, 3, 4)])
  ref <- got * NA_real_
  for (j in seq_len(dim(raw)[3])) for (i in seq_len(dim(raw)[4]))
    ref[, j, i] <- .ref_wz(raw[, , j, i])
  expect_identical(is.na(got), is.na(ref))
  keep <- !is.na(ref)
  expect_equal(got[keep], ref[keep], tolerance = 1e-4)
})

test_that("medoid returns the observed vector nearest the geomedian", {
  cube <- .mb_cube()
  got <- execute_plan(plan_lazy(reduce_over(cube, medoid(), over = "t")))
  raw <- execute_plan(plan_lazy(cube))
  ref <- got * NA_real_
  for (j in seq_len(dim(raw)[3])) for (i in seq_len(dim(raw)[4])) {
    Y <- raw[, , j, i]
    ok <- colSums(is.na(Y)) == 0L
    if (!any(ok)) { ref[, j, i] <- NaN; next }
    m <- .ref_wz(Y)
    d <- sqrt(colSums((Y[, ok, drop = FALSE] - m)^2))
    ref[, j, i] <- Y[, ok, drop = FALSE][, which.min(d)]
  }
  expect_identical(is.na(got), is.na(ref))
  keep <- !is.na(ref)
  expect_equal(got[keep], ref[keep], tolerance = 1e-4)
})

test_that("multiband reducers: distributed == single-threaded", {
  skip_if(!requireNamespace("garry", quietly = TRUE), "garry not installed")
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")

  local_pools(2, 1, gdal_config = TRUE)
  old <- options(garry.chunk_target_px = 400)
  on.exit(options(old), add = TRUE)

  p <- plan_lazy(reduce_over(.mb_cube(), geomedian(iters = 6L), over = "t"))
  expect_equal(execute_plan_mirai(p), execute_plan(p), tolerance = 1e-5)
})

test_that("multiband reducers validate their inputs", {
  expect_error(geomedian(iters = 0), "positive")
  expect_error(medoid(eps = 0), "positive")
  # a plain (t, y, x) stack is not a multiband cube
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  st <- lazy_stack(list(s(), s() * 2), along = "t")
  expect_error(
    execute_plan(plan_lazy(reduce_over(st, geomedian(), over = "t"))),
    "band, t, y, x")
})
