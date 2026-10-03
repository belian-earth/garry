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

test_that(".sign_href joins queries and re-signs idempotently", {
  tok <- "st=abc&se=2030-01-01T00%3A00%3A00Z&sig=xyz"
  plain <- "https://x.blob.core.windows.net/a/B04.tif"
  expect_equal(garry:::.sign_href(plain, tok), paste0(plain, "?", tok))
  # existing non-SAS query: extend with &, never a second ?
  expect_equal(
    garry:::.sign_href(paste0(plain, "?foo=bar"), tok),
    paste0(plain, "?foo=bar&", tok)
  )
  # already signed: token replaced, not stacked
  once <- garry:::.sign_href(plain, "st=old&sig=old")
  expect_equal(garry:::.sign_href(once, tok), paste0(plain, "?", tok))
  expect_equal(lengths(regmatches(once, gregexpr("?", once, fixed = TRUE))), 1L)
})

test_that("stac_sign_mpc signs each item with its own collection's token", {
  skip_if_not_installed("rstac")
  skip_if_not_installed("httr2")
  seen <- character(0)
  local_mocked_bindings(.mpc_token = function(collection, ...) {
    seen <<- c(seen, collection)
    paste0("sv=1&sig=", collection)
  })
  item <- function(coll) list(collection = coll, assets = list(B1 = list(href = "https://a.blob.core.windows.net/c/x.tif")))
  items <- structure(list(features = list(item("hls2-l30"), item("hls2-s30"), item("hls2-l30"))), class = c("doc_items", "list"))
  out <- stac_sign_mpc(items)
  expect_setequal(seen, c("hls2-l30", "hls2-s30"))
  expect_match(out$features[[2L]]$assets$B1$href, "sig=hls2-s30$")
  expect_match(out$features[[3L]]$assets$B1$href, "sig=hls2-l30$")
})

test_that("re-signing replaces only the SAS parameters", {
  h <- "https://a.blob.core.windows.net/c/x.tif?version=2&sv=old&sig=old"
  out <- .sign_href(h, "sv=new&se=2030-01-01T00%3A00%3A00Z&sig=new")
  expect_identical(
    out,
    "https://a.blob.core.windows.net/c/x.tif?version=2&sv=new&se=2030-01-01T00%3A00%3A00Z&sig=new"
  )
})

test_that("a cached token inside the margin is a cache miss", {
  coll <- paste0("garry-test-", basename(tempfile()))
  on.exit({
    rm(list = intersect(coll, ls(.mpc_token_cache)), envir = .mpc_token_cache)
    unlink(.mpc_token_file(coll))
  }, add = TRUE)
  exp <- format(Sys.time() + 300, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  assign(coll, list(token = "t", "msft:expiry" = exp), envir = .mpc_token_cache)
  expect_identical(.mpc_token_lookup(coll), "t")
  expect_null(.mpc_token_lookup(coll, margin = 600))
})
