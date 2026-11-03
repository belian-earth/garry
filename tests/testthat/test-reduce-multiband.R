# Multivariate temporal reducers (geomedian / medoid) over a
# (band, t, y, x) cube: 4D stack grid algebra; both reducers match
# brute-force pure-R references at every pixel including NaN-masked
# timesteps; the medoid returns an observed spectrum. The cube and the
# references are in helper-kernels.R; test-route-kernels.R runs them on
# daemons.

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

test_that("the cube's mask varies by pixel", {
  raw <- .mb_values()
  .expect_partial_nan(raw[, 3L, , ])
  expect_identical(is.nan(raw[, 2L, 1L, 1L]), c(TRUE, FALSE))
  expect_true(all(is.nan(raw[, , 8L, 12L])))
})

test_that("geomedian matches the pure-R Weiszfeld at every pixel", {
  raw <- .mb_values()
  got <- execute_plan(plan_lazy(reduce_over(.mb_cube(), geomedian(), over = "t")))
  expect_identical(dim(got), dim(raw)[c(1, 3, 4)])
  ref <- .ref_pixels(raw, .ref_wz)
  expect_identical(is.na(got), is.na(ref))
  keep <- !is.na(ref)
  expect_equal(got[keep], ref[keep], tolerance = 1e-4)
})

test_that("medoid returns the observed vector nearest the geomedian", {
  raw <- .mb_values()
  got <- execute_plan(plan_lazy(reduce_over(.mb_cube(), medoid(), over = "t")))
  ref <- .ref_pixels(raw, function(Y) {
    ok <- colSums(is.na(Y)) == 0L
    if (!any(ok)) return(rep(NaN, nrow(Y)))
    d <- sqrt(colSums((Y[, ok, drop = FALSE] - .ref_wz(Y))^2))
    Y[, ok, drop = FALSE][, which.min(d)]
  })
  expect_identical(is.na(got), is.na(ref))
  keep <- !is.na(ref)
  expect_equal(got[keep], ref[keep], tolerance = 1e-4)
})

test_that("geomedian starts from the mean of the dates with every band valid", {
  raw <- .mb_values()
  got <- execute_plan(plan_lazy(reduce_over(.mb_cube(), geomedian(1L), over = "t")))
  ref <- .ref_pixels(raw, function(Y) .ref_wz(Y, iters = 1L))
  keep <- !is.na(ref)
  expect_equal(got[keep], ref[keep], tolerance = 1e-6)
})

test_that("a plain array gets the answers of a traced one", {
  raw <- .mb_values()
  for (fn in list(geomedian(3L), medoid(3L))) {
    expect_equal(
      fn(raw, 2L),
      execute_plan(plan_lazy(reduce_over(.mb_cube(), fn, over = "t"))),
      tolerance = 1e-5
    )
  }
})

test_that("a single pixel keeps its axes on a plain array", {
  for (fn in list(geomedian(2L), medoid(2L))) {
    expect_identical(dim(fn(array(as.numeric(1:6), c(2L, 3L, 1L, 1L)), 2L)), c(2L, 1L, 1L))
  }
})

test_that("an integer cube solves in float", {
  g <- graph_new()
  src <- function(v) lazy_source(fixture_tile(v, type = "Int16"), graph = g)
  stk <- function(v) lazy_stack(list(a = src(v), b = src(v + 2L), c = src(v + 10L)), along = "t")
  cube <- lazy_stack(list(A = stk(1L), B = stk(5L)), along = "band")
  expect_identical(cube@grid@dtype, "i16")
  Y <- rbind(c(1, 3, 11), c(5, 7, 15))
  got <- execute_plan(plan_lazy(reduce_over(cube, geomedian(), over = "t")))
  expect_equal(got[, 1L, 1L], .ref_wz(Y), tolerance = 1e-4)
  got <- execute_plan(plan_lazy(reduce_over(cube, medoid(), over = "t")))
  expect_equal(got[, 1L, 1L], c(3, 7))
})

test_that("a joint strip's budget grows with its bands", {
  x <- list(geomedian(), medoid())
  for (fn in x) {
    expect_identical(attr(fn, "joint_cubes"), garry:::.mb_joint_cubes)
  }
  plan_cubes <- function(nb) {
    g <- graph_new()
    src <- function() lazy_source(fixture_tile(1), graph = g)
    stk <- function() lazy_stack(list(a = src(), b = src()), along = "t")
    cube <- lazy_stack(stats::setNames(lapply(seq_len(nb), function(i) stk()), paste0("b", seq_len(nb))), along = "band")
    top <- reduce_over(cube, geomedian(), over = "t")
    gg <- function(id) graph_get(top@graph, id)
    garry:::.cd_joint_spec(gg, gg(top@node_id))$cubes
  }
  expect_identical(plan_cubes(4L), 2 * plan_cubes(2L))
})

test_that("multiband reducers validate their inputs", {
  expect_error(geomedian(iters = 0), "positive")
  # a plain (t, y, x) stack is not a multiband cube
  f <- fixture_gradient_f32()
  g <- graph_new(); s <- function() lazy_source(f, graph = g)
  st <- lazy_stack(list(s(), s() * 2), along = "t")
  expect_error(
    execute_plan(plan_lazy(reduce_over(st, geomedian(), over = "t"))),
    "band, t, y, x")
})
