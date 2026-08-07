# Task-scoped read retry (.gdal_with_retry): a whole-operation read /
# fetch / warp failure (curl timeout, TLS reset, failed open) below
# GDAL's per-request HTTP retry is re-attempted with jittered
# exponential backoff before the read_fail contract fires.

test_that("a transient failure is retried and succeeds", {
  withr::local_options(garry.read_retry = 2L)
  n <- 0L
  thunk <- function() {
    n <<- n + 1L
    if (n < 2L) stop("transient reset")
    "ok"
  }
  expect_warning(res <- .gdal_with_retry(thunk, "read"),
                 "attempt 1 of 3")
  expect_identical(res, "ok")
  expect_identical(n, 2L)
})

test_that("a persistent failure exhausts the retries and propagates", {
  withr::local_options(garry.read_retry = 1L)
  n <- 0L
  expect_error(
    suppressWarnings(
      .gdal_with_retry(function() { n <<- n + 1L; stop("still down") },
                       "fetch")),
    "still down")
  expect_identical(n, 2L)   # one retry, then the final attempt
})

test_that("read_retry = 0 is a single attempt with no warning", {
  withr::local_options(garry.read_retry = 0L)
  n <- 0L
  expect_no_warning(expect_error(
    .gdal_with_retry(function() { n <<- n + 1L; stop("down") }, "read"),
    "down"))
  expect_identical(n, 1L)
})

test_that(".exec_read_padded survives one transient read failure", {
  withr::local_options(garry.read_retry = 1L)
  f <- fixture_gradient_f32()
  want <- collect(lazy_source(f) + 0)
  n <- 0L
  real <- gdal_read_window
  testthat::local_mocked_bindings(
    gdal_read_window = function(...) {
      n <<- n + 1L
      if (n == 1L) stop("transient vsicurl reset")
      real(...)
    },
    .package = "garry")
  got <- suppressWarnings(collect(lazy_source(f) + 0))
  expect_gte(n, 2L)   # the failed attempt was retried, not fatal
  expect_identical(got, want)
})
