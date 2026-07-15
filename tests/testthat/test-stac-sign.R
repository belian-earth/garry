# MPC token caching for stac_sign_mpc(). The token REQUEST needs the network, so
# here we exercise the cache + signing logic with a seeded token (no request).

test_that("stac_sign_mpc signs asset hrefs from a cached token (no request)", {
  skip_if_not_installed("rstac")
  skip_if_not_installed("httr2")
  coll <- "test-coll-sign"
  tok <- list(token = "st=abc&sig=xyz",
              `msft:expiry` = format(Sys.time() + 3600, "%Y-%m-%dT%H:%M:%SZ",
                                     tz = "UTC"))
  assign(coll, tok, envir = garry:::.mpc_token_cache)
  on.exit(suppressWarnings(rm(list = coll, envir = garry:::.mpc_token_cache)),
          add = TRUE)

  items <- list(features = list(list(
    collection = coll,
    assets = list(
      B04 = list(href = "https://x.blob.core.windows.net/a/B04.tif"),
      B03 = list(href = "https://x.blob.core.windows.net/a/B03.tif")))))
  signed <- stac_sign_mpc(items)                       # cache hit -> no network

  expect_equal(signed$features[[1L]]$assets$B04$href,
               "https://x.blob.core.windows.net/a/B04.tif?st=abc&sig=xyz")
  expect_equal(signed$features[[1L]]$assets$B03$href,
               "https://x.blob.core.windows.net/a/B03.tif?st=abc&sig=xyz")
})

test_that(".mpc_token_lookup honours expiry across memory and disk", {
  # expired memory entry -> NULL (and dropped)
  coll <- "test-coll-expired"
  assign(coll, list(token = "old",
                    `msft:expiry` = format(Sys.time() - 60, "%Y-%m-%dT%H:%M:%SZ",
                                           tz = "UTC")),
         envir = garry:::.mpc_token_cache)
  expect_null(garry:::.mpc_token_lookup(coll))
  expect_false(exists(coll, envir = garry:::.mpc_token_cache, inherits = FALSE))

  # valid disk entry -> returned and promoted to the memory cache
  dcoll <- "test-coll-disk"
  f <- garry:::.mpc_token_file(dcoll)
  saveRDS(list(token = "disktok",
               `msft:expiry` = format(Sys.time() + 3600, "%Y-%m-%dT%H:%M:%SZ",
                                      tz = "UTC")), f)
  on.exit({
    unlink(f)
    suppressWarnings(rm(list = dcoll, envir = garry:::.mpc_token_cache))
  }, add = TRUE)
  expect_equal(garry:::.mpc_token_lookup(dcoll), "disktok")
  expect_true(exists(dcoll, envir = garry:::.mpc_token_cache, inherits = FALSE))
})
