# Daemon memory hygiene (workstream B): .garry_malloc_trim returns
# arena pages (glibc), .daemon_hygiene(deep) evicts the jit cache, and
# a post-hygiene run on the same pools stays correct (the jit-miss
# resend covers evicted key-only launches).

test_that(".garry_malloc_trim runs (glibc) and is a safe no-op elsewhere", {
  got <- garry:::.garry_malloc_trim()
  expect_true(isTRUE(got) || isFALSE(got))
  if (identical(Sys.info()[["sysname"]], "Linux")) expect_true(got)
})

test_that(".daemon_hygiene deep-evicts the jit cache", {
  e <- garry:::.daemon_cache
  e[["spike"]] <- function() 1
  expect_true(length(ls(e)) >= 1L)
  garry:::.daemon_hygiene(deep = TRUE)
  expect_length(ls(e), 0L)
})

test_that("garry_pool_hygiene runs and the pools stay serviceable", {
  skip_if(!requireNamespace("garry", quietly = TRUE),
          "garry not installed for daemons")
  local_pools(2, 1)
  f <- fixture_gradient_f32()
  want <- collect(lazy_source(f) + 1, distributed = FALSE)
  got1 <- collect(lazy_source(f) + 1, distributed = TRUE)
  garry_pool_hygiene(deep = TRUE)      # wipes every daemon jit cache
  got2 <- collect(lazy_source(f) + 1, distributed = TRUE)
  expect_equal(got1, want, tolerance = 1e-6, ignore_attr = TRUE)
  expect_equal(got2, want, tolerance = 1e-6, ignore_attr = TRUE)
})

test_that(".daemon_gc_after defers the pass until the transient budget fills", {
  st <- garry:::.daemon_gc_state
  old <- options(garry.daemon_gc_mb = 1)
  on.exit({
    options(old)
    st$bytes <- 0
  }, add = TRUE)
  st$bytes <- 0
  expect_false(garry:::.daemon_gc_after(0.4 * 2^20))
  expect_false(garry:::.daemon_gc_after(0.4 * 2^20))
  expect_equal(st$bytes, 0.8 * 2^20)
  expect_true(garry:::.daemon_gc_after(0.4 * 2^20))   # 1.2 MB >= 1 MB
  expect_equal(st$bytes, 0)
  # a single big transient always runs the pass
  expect_true(garry:::.daemon_gc_after(8 * 2^20))
  # budget 0: every task cleans up, the historical behaviour
  options(garry.daemon_gc_mb = 0)
  expect_true(garry:::.daemon_gc_after(1))
})

test_that(".payload_bytes sizes raw payloads, R vectors and lists", {
  pb <- garry:::.payload_bytes
  expect_identical(pb(raw(10)), 10)
  expect_identical(pb(numeric(3)), 24)
  expect_identical(pb(integer(3)), 12)
  expect_identical(pb(list(raw(4), list(numeric(1), "x"))), 12)
})

test_that("the writer reopens a GTiff with threaded compression", {
  f <- fixture_gradient_f32()
  p <- tempfile(fileext = ".tif")
  file.copy(f, p)
  ds <- gdal_open_update(p)
  on.exit(ds$close(), add = TRUE)
  expect_true(inherits(ds, "Rcpp_GDALRaster"))
  ds$write(1L, 0L, 0L, 60L, 40L, as.numeric(t(matrix(2, 40, 60))))
  ds$close()
  expect_equal(unique(as.vector(gdal_read_window(p, 1L, 0L, 0L, 60L, 40L))), 2)
})
