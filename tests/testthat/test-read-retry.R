# Task-scoped read retry (.gdal_with_retry): a whole-operation read /
# fetch / warp failure (curl timeout, TLS reset, failed open) below
# GDAL's per-request HTTP retry is re-attempted with jittered
# exponential backoff before the run aborts.

test_that("a transient failure is retried and succeeds", {
  withr::local_options(garry.read_retry = 2L)
  .local_no_backoff()
  n <- 0L
  thunk <- function() {
    n <<- n + 1L
    if (n < 2L) stop("transient reset")
    "ok"
  }
  expect_warning(res <- .gdal_with_retry(thunk, "read", "a.tif"),
                 "attempt 1 of 3")
  expect_identical(res, "ok")
  expect_identical(n, 2L)
})

test_that("a persistent failure exhausts the retries and propagates", {
  withr::local_options(garry.read_retry = 1L)
  .local_no_backoff()
  n <- 0L
  expect_error(
    suppressWarnings(
      .gdal_with_retry(function() { n <<- n + 1L; stop("still down") },
                       "fetch", "a.tif")),
    "still down")
  expect_identical(n, 2L)   # one retry, then the final attempt
})

test_that("read_retry = 0 is a single attempt with no warning", {
  withr::local_options(garry.read_retry = 0L)
  n <- 0L
  expect_no_warning(expect_error(
    .gdal_with_retry(function() { n <<- n + 1L; stop("down") }, "read", "a.tif"),
    "down"))
  expect_identical(n, 1L)
})

test_that("the last failure names the source and the cause", {
  withr::local_options(garry.read_retry = 0L)
  err <- expect_error(
    .gdal_with_retry(function() stop("connection reset"), "fetch", "/vsicurl/https://x.io/a.tif?sig=tok"),
    class = "garry_read_error"
  )
  expect_match(conditionMessage(err), "fetch failed", fixed = TRUE)
  expect_match(conditionMessage(err), "a.tif", fixed = TRUE)
  expect_match(conditionMessage(err), "connection reset", fixed = TRUE)
  expect_no_match(conditionMessage(err), "tok", fixed = TRUE) # the signed token stays out of logs
})

test_that("a signed URL's token stays out of GDAL's own text", {
  withr::local_options(garry.read_retry = 1L)
  .local_no_backoff()
  url <- "/vsicurl/https://acct.blob.core.windows.net/c/a.tif?se=2026&sig=tok%3D"
  msg <- paste0("'", url, "' not recognized as being in a supported file format")
  warned <- NULL
  err <- expect_error(
    withCallingHandlers(
      .gdal_with_retry(function() stop(msg), "read", url),
      warning = function(w) {
        warned <<- conditionMessage(w)
        invokeRestart("muffleWarning")
      }
    ),
    class = "garry_read_error"
  )
  expect_match(conditionMessage(err), "a.tif", fixed = TRUE)
  expect_no_match(conditionMessage(err), "sig=", fixed = TRUE)
  expect_no_match(warned, "sig=", fixed = TRUE)
  # a local path keeps its text
  expect_identical(garry:::.url_scrub("/data/a?b.tif"), "/data/a?b.tif")
})

test_that("garry's own errors are not retried or relabelled", {
  withr::local_options(garry.read_retry = 2L)
  n <- 0L
  expect_error(
    .gdal_with_retry(function() {
      n <<- n + 1L
      cli::cli_abort("refused", class = c("garry_source_error", "garry_error"))
    }, "read", "a.tif"),
    class = "garry_source_error"
  )
  expect_identical(n, 1L)
})

test_that(".exec_read_padded survives one transient read failure", {
  withr::local_options(garry.read_retry = 1L)
  .local_no_backoff()
  f <- fixture_gradient_f32()
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
  expect_equal(unclass(got), .fixture_values(60, 40), tolerance = 0, ignore_attr = TRUE)
})
