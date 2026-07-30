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

test_that(".mpc_resign passes the URL through when the token request fails", {
  testthat::local_mocked_bindings(
    .mpc_token = function(collection, ...) stop("MPC down"),
    .package = "garry")
  u <- .mr_url(60)
  expect_identical(garry:::.mpc_resign(u, margin = 600), u)
})
