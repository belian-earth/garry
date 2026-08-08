# Pipeline tail levers: strip-decomposed band medians are byte-identical
# to whole-band jobs and match the single-process oracle; the
# content-addressed kernel cache + fetch-window warm mean a repeat
# collect compiles nothing new; g_fill builds device constants.


skip_if(!requireNamespace("garry", quietly = TRUE),
        "garry not installed for daemons")

test_that(".gd_strip_bounds tiles exactly with at most two heights", {
  for (ny in c(1L, 7L, 40L, 1480L)) {
    for (ns in c(1L, 2L, 3L, 6L, 64L)) {
      b <- garry:::.gd_strip_bounds(ny, ns)
      starts <- vapply(b, `[[`, integer(1), 1L)
      heights <- vapply(b, `[[`, integer(1), 2L)
      expect_identical(starts[[1L]], 0L)
      expect_identical(starts[-1L], (starts + heights)[-length(b)])  # contiguous
      expect_identical(sum(heights), ny)                             # covers
      expect_true(all(heights >= 1L))
      expect_lte(length(unique(heights)), 2L)                        # <=2 shapes
      expect_lte(length(b), max(1L, min(ns, ny)))
    }
  }
})

test_that("g_fill builds a device constant equal to the R fill", {
  skip_if(!rlang::is_installed("anvl"), "anvl not installed")
  a <- g_fill(1.5, c(2L, 3L))
  expect_equal(g_download(a), matrix(1.5, 2, 3), ignore_attr = TRUE)
})

test_that("strip-decomposed pipeline equals whole-band jobs and the oracle", {
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  local_pools(2, 2)
  old <- options(garry.gd_parallel = TRUE)
  on.exit(options(old), add = TRUE)
  x <- .gg_masked_composite(open = 1L, dilate = 1L)
  want <- collect(x, distributed = FALSE)
  res <- lapply(c(1L, 3L), function(ns) {
    old2 <- options(garry.gd_strips = ns)
    on.exit(options(old2), add = TRUE)
    got <- collect(x, distributed = TRUE)
    expect_identical(garry_last_route(), "composite_direct")
    got
  })
  expect_identical(res[[1L]], res[[2L]])   # strips reassemble byte-identically
  .gg_close(res[[2L]], want)
})

test_that("repeat collect creates no new pipeline kernels (cache + warm)", {
  skip_if(!garry::.g_has_raw_upload(), "installed anvl lacks raw payload support")
  local_pools(2, 2)
  old <- options(garry.gd_parallel = TRUE, garry.gd_strips = 2)
  on.exit(options(old), add = TRUE)
  x <- .gg_masked_composite()
  creates <- function() sum(vapply(garry:::.comp_profiles(), function(p)
    mirai::mirai(garry::.daemon_jit_creates(), .compute = p)[], integer(1)))
  invisible(collect(x, distributed = TRUE))
  c1 <- creates()
  expect_gte(c1, 1L)                       # warm or first use compiled something
  invisible(collect(x, distributed = TRUE))
  expect_identical(creates(), c1)          # second run: every kernel cache-hits
})
