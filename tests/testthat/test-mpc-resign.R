# Expiry-aware MPC re-signing (io review R4): hrefs signed once at
# discovery are re-signed at DISPATCH time when their SAS token nears
# expiry, via the account/container token endpoint and the existing
# collection-token cache. Fully offline (token requests mocked).

.mr_url <- function(expires_in, host = "acc.blob.core.windows.net") {
  se <- utils::URLencode(
    format(Sys.time() + expires_in, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    reserved = TRUE)
  paste0("/vsicurl/https://", host, "/cont/a/b.tif?sv=1&se=", se, "&sig=s")
}

test_that(".sas_expiry parses SAS expiry stamps", {
  future <- format(Sys.time() + 3600, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  want <- as.numeric(as.POSIXct(future, format = "%Y-%m-%dT%H:%M:%SZ",
                                tz = "UTC"))
  expect_equal(garry:::.sas_expiry(paste0("sv=x&se=", future)), want)
  expect_true(is.na(garry:::.sas_expiry("sv=x&sig=y")))
})

test_that(".mpc_resign leaves fresh, unsigned and non-MPC URLs alone", {
  fresh <- .mr_url(3600)
  expect_identical(garry:::.mpc_resign(fresh), fresh)
  plain <- "https://acc.blob.core.windows.net/cont/x.tif"
  expect_identical(garry:::.mpc_resign(plain), plain)
  other <- "https://example.com/x.tif?se=2000-01-01T00:00:00Z"
  expect_identical(garry:::.mpc_resign(other), other)
  local <- "/data/tiles/x.tif"
  expect_identical(garry:::.mpc_resign(local), local)
})

test_that(".mpc_resign swaps a near-expiry token for a fresh cached one", {
  seen <- NULL
  testthat::local_mocked_bindings(
    .mpc_token = function(collection, ...) {
      seen <<- collection
      "FRESHTOK=1"
    },
    .package = "garry")
  got <- garry:::.mpc_resign(.mr_url(60), margin = 600)
  expect_identical(
    got, "/vsicurl/https://acc.blob.core.windows.net/cont/a/b.tif?FRESHTOK=1")
  expect_identical(seen, "acc/cont")     # account/container token endpoint
})

test_that("a failed re-sign warns once while the URL lasts, and aborts past it", {
  calls <- 0L
  testthat::local_mocked_bindings(
    .mpc_token = function(collection, ...) {
      calls <<- calls + 1L
      stop("MPC down")
    },
    .package = "garry")
  u <- c(.mr_url(60), sub("b.tif", "c.tif", .mr_url(60), fixed = TRUE))
  expect_warning(got <- garry:::.mpc_resign(u, margin = 600), "MPC down")
  expect_identical(got, u) # both still valid
  expect_identical(calls, 1L) # one request per container, one warning
  err <- expect_error(garry:::.mpc_resign(.mr_url(-60), margin = 600), class = "garry_read_error")
  expect_match(conditionMessage(err), "expired", fixed = TRUE)
  expect_match(conditionMessage(err), "MPC down", fixed = TRUE)
})

test_that("a re-sign at run time names httr2 when it is missing", {
  testthat::local_mocked_bindings(.mpc_token_lookup = function(...) NULL, .package = "garry")
  testthat::local_mocked_bindings(
    check_installed = function(pkg, ...) stop("package ", pkg, " is missing"),
    .package = "rlang"
  )
  err <- expect_error(garry:::.mpc_resign(.mr_url(-60), margin = 600), class = "garry_read_error")
  expect_match(conditionMessage(err), "httr2", fixed = TRUE)
})

test_that("signing and re-signing both send the MPC_TOKEN key", {
  skip_if_not_installed("rstac")
  skip_if_not_installed("httr2", "1.1.0")
  withr::local_envvar(MPC_TOKEN = "the-key")
  sent <- character(0)
  httr2::local_mocked_responses(function(req) {
    sent <<- c(sent, req$headers[["Ocp-Apim-Subscription-Key"]])
    httr2::response_json(body = list(token = "st=1"))
  })
  testthat::local_mocked_bindings(
    .mpc_token_lookup = function(...) NULL,
    .cache_save = function(...) invisible(),
    .package = "garry"
  )
  held <- garry:::.mpc_token_cache
  withr::defer(rm(list = intersect(c("coll", "acc/cont"), ls(held)), envir = held))
  stac_sign_mpc(list(features = list(list(
    collection = "coll",
    assets = list(a = list(href = "https://acc.blob.core.windows.net/cont/a.tif"))
  ))))
  garry:::.mpc_resign(.mr_url(-60), margin = 600)
  expect_identical(sent, c("the-key", "the-key"))
})
